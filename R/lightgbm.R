#' Boosted trees with lightgbm
#'
#' `train_lightgbm` is a wrapper for `lightgbm` tree-based models
#' where all of the model arguments are in the main function.
#'
#' This is an internal function, not meant to be directly called by the user.
#'
#' @param x A data frame or matrix of predictors
#' @param y A vector (factor or numeric) or matrix (numeric) of outcome data.
#' @param max_depth An integer for the maximum depth of the tree.
#' @param num_iterations An integer for the number of boosting iterations.
#' @param learning_rate A numeric value between zero and one to control the learning rate.
#' @param feature_fraction Fraction of predictors that will be randomly sampled
#' at each split.
#' @param min_data_in_leaf A numeric value for the minimum sum of instances needed
#'  in a child to continue to split.
#' @param min_gain_to_split A number for the minimum loss reduction required to make a
#'  further partition on a leaf node of the tree.
#' @param bagging_fraction Subsampling proportion of rows.
#' @param early_stopping_rounds Number of iterations without an improvement in
#' the objective function occur before training should be halted.
#' @param validation The _proportion_ of the training data that are used for
#' performance assessment and potential early stopping.
#' @param counts A logical; should `feature_fraction` be interpreted as the
#' _number_ of predictors that will be randomly sampled at each split?
#' `TRUE` indicates that `mtry` will be interpreted in its sense as a _count_,
#' `FALSE` indicates that the argument will be interpreted in its sense as a
#' _proportion_.
#' @param quiet A logical; should logging by [lightgbm::lgb.train()] be muted?
#' @param ... Other options to pass to [lightgbm::lgb.train()]. Arguments
#' will be correctly routed to the `param` argument, or as a main argument,
#' depending on their name.
#' @return A fitted `lightgbm.Model` object.
#' @keywords internal
#' @export
train_lightgbm <- function(x, y, max_depth = -1, num_iterations = 100, learning_rate = 0.1,
                           feature_fraction = 1, min_data_in_leaf = 20,
                           min_gain_to_split = 0, bagging_fraction = 1,
                           early_stopping_rounds = NULL, validation = 0,
                           counts = TRUE, quiet = FALSE, ...) {

  force(x)
  force(y)

  if (!is.logical(quiet)) {
    rlang::abort("'quiet' should be a logical value.")
  }

  feature_fraction <-
    process_mtry(feature_fraction = feature_fraction,
                 counts = counts, x = x, is_missing = missing(feature_fraction))

  args <- list(
    param = list(
      num_iterations = num_iterations,
      learning_rate = learning_rate,
      max_depth = max_depth,
      feature_fraction = feature_fraction,
      min_data_in_leaf = min_data_in_leaf,
      min_gain_to_split = min_gain_to_split,
      bagging_fraction = bagging_fraction
    ),
    main = list(
      early_stopping_rounds = early_stopping_rounds,
      ...
    )
  )

  args <- process_objective_function(args, x, y)

  if (args$param$objective != "regression") {
    y <- as.numeric(y) - 1
  }

  args <- process_parallelism(args)

  args <- process_data(args, x, y, validation, missing(validation),
                       early_stopping_rounds)

  args <- sort_args(args)

  if (!"verbose" %in% names(args$main)) {
    args$main$verbose <- 1L
  }

  compacted <-
    c(
      list(param = args$param),
      args$main[names(args$main) != "data"],
      list(data = quote(args$main$data))
    )

  call <- parsnip::make_call(fun = "lgb.train", ns = "lightgbm", compacted)

  if (quiet) {
    junk <- utils::capture.output(res <- rlang::eval_tidy(call, env = rlang::current_env()))
  } else {
    res <- rlang::eval_tidy(call, env = rlang::current_env())
  }

  res
}

process_mtry <- function(feature_fraction, counts, x, is_missing) {
  if (!is.logical(counts)) {
    rlang::abort("'counts' should be a logical value.")
  }

  ineq <- if (counts) {"greater"} else {"less"}
  interp <- if (counts) {"count"} else {"proportion"}
  opp <- if (!counts) {"count"} else {"proportion"}

  if ((feature_fraction < 1 & counts) | (feature_fraction > 1 & !counts)) {
    rlang::abort(
      glue::glue(
        "The supplied argument `mtry = {feature_fraction}` must be ",
        "{ineq} than or equal to 1. \n\n`mtry` is currently being interpreted ",
        "as a {interp} rather than a {opp}. Supply `counts = {!counts}` to ",
        "`set_engine` to supply this argument as a {opp} rather than ",
        # TODO: link to parsnip's lightgbm docs instead here
        "a {interp}. \n\nSee `?train_lightgbm` for more details."
      ),
      call = NULL
    )
  }

  if (rlang::is_call(feature_fraction)) {
    if (rlang::call_name(feature_fraction) == "tune") {
      rlang::abort(
        glue::glue(
          "The supplied `mtry` parameter is a call to `tune`. Did you forget ",
          "to optimize hyperparameters with a tuning function like `tune::tune_grid`?"
        ),
        call = NULL
      )
    }
  }

  if (counts && !is_missing) {
    feature_fraction <- feature_fraction / ncol(x)
  }

  feature_fraction
}

process_objective_function <- function(args, x, y) {
  # set the "objective" param argument, clear it out from main args
  if (!any(names(args$main) %in% c("objective"))) {
    if (is.numeric(y)) {
      args$param$objective <- "regression"
    } else {
      lvl <- levels(y)
      lvls <- length(lvl)
      y <- as.numeric(y) - 1
      if (lvls == 2) {
        args$param$num_class <- 1
        args$param$objective <- "binary"
      } else {
        args$param$num_class <- lvls
        args$param$objective <- "multiclass"
      }
    }
  } else {
    args$param$objective <- args$main$objective
  }

  args$main$objective <- NULL

  args
}

# supply the number of threads as num_threads in params, clear out
# any other thread args that might be passed as main arguments
process_parallelism <- function(args) {
  if (!is.null(args$main["num_threads"])) {
    args$param$num_threads <- args$main[names(args$main) == "num_threads"]
    args$main[names(args$main) == "num_threads"] <- NULL
  } else {
    args$param$num_threads <- foreach::getDoParWorkers()
  }

  args
}

process_data <- function(args, x, y, validation, missing_validation,
                         early_stopping_rounds) {
  #                                           trn_index       | val_index
  #                                         ----------------------------------
  #  needs_validation &  missing_validation | 1:n               1:n
  #  needs_validation & !missing_validation | sample(1:n, m)    setdiff(trn_index, 1:n)
  # !needs_validation &  missing_validation | 1:n               NULL
  # !needs_validation & !missing_validation | sample(1:n, m)    setdiff(trn_index, 1:n)

  n <- nrow(x)
  needs_validation <- !is.null(early_stopping_rounds)

  if (missing_validation) {
    trn_index <- 1:n
    if (needs_validation) {
      val_index <- trn_index
    } else {
      val_index <- NULL
    }
  } else {
    m <- min(floor(n * (1 - validation)) + 1, n - 1)
    trn_index <- sample(1:n, size = max(m, 2))
    val_index <- setdiff(1:n, trn_index)
  }

  args$main$data <-
    lightgbm::lgb.Dataset(
      data = prepare_df_lgbm(x[trn_index, , drop = FALSE]),
      label = y[trn_index],
      categorical_feature = categorical_columns(x[trn_index, , drop = FALSE]),
      params = list(feature_pre_filter = FALSE)
    )

  if (!is.null(val_index)) {
    args$main$valids <-
      list(validation =
          lightgbm::lgb.Dataset(
          data = prepare_df_lgbm(x[val_index, , drop = FALSE]),
          label = y[val_index],
          categorical_feature = categorical_columns(x[val_index, , drop = FALSE]),
          params = list(feature_pre_filter = FALSE)
        )
      )
  }

  args
}

# transfers arguments between param and main arguments
sort_args <- function(args) {
  # warn on arguments that won't be passed along
  protected <- c("obj", "init_model", "colnames",
                 "categorical_feature", "callbacks", "reset_data")

  if (any(names(args$main) %in% protected)) {
    protected_args <- names(args$main[names(args$main) %in% protected])

    rlang::warn(
      glue::glue(
        "The following argument(s) are guarded by bonsai and will not ",
        "be passed to `lgb.train`: {glue::glue_collapse(protected_args, sep = ', ')}"
      )
    )

    args$main[protected_args] <- NULL
  }

  # dots are deprecated in lgb.train -- pass to param instead
  to_main   <- c("nrounds", "eval", "verbose", "record", "eval_freq",
                 "early_stopping_rounds", "data", "valids")

  args$param <- c(args$param, args$main[!names(args$main) %in% to_main])

  args$main[!names(args$main) %in% to_main] <- NULL

  args
}

#' Internal functions
#'
#' Not intended for direct use.
#'
#' @keywords internal
#' @export
#' @rdname lightgbm_helpers
predict_lightgbm_classification_prob <- function(object, new_data, ...) {
  p <- stats::predict(object$fit, prepare_df_lgbm(new_data), reshape = TRUE, ...)

  if(is.vector(p)) {
    p <- tibble::tibble(p1 = 1 - p, p2 = p)
  }

  colnames(p) <- object$lvl

  tibble::as_tibble(p)
}

#' @keywords internal
#' @export
#' @rdname lightgbm_helpers
predict_lightgbm_classification_class <- function(object, new_data, ...) {
  p <- predict_lightgbm_classification_prob(object, prepare_df_lgbm(new_data), ...)

  q <- apply(p, 1, function(x) which.max(x))

  names(p)[q]
}

#' @keywords internal
#' @export
#' @rdname lightgbm_helpers
predict_lightgbm_classification_raw <- function(object, new_data, ...) {
  stats::predict(object$fit, prepare_df_lgbm(new_data), reshape = TRUE, rawscore = TRUE, ...)
}

#' @keywords internal
#' @export
#' @rdname lightgbm_helpers
predict_lightgbm_regression_numeric <- function(object, new_data, ...) {
  p <-
    stats::predict(
      object$fit,
      prepare_df_lgbm(new_data),
      reshape = TRUE,
      params = list(predict_disable_shape_check = TRUE),
      ...
    )
  p
}



#' @keywords internal
#' @export
#' @rdname lightgbm_helpers
multi_predict._lgb.Booster <- function(object, new_data, type = NULL, trees = NULL, ...) {
  if (any(names(rlang::enquos(...)) == "newdata")) {
    rlang::abort("Did you mean to use `new_data` instead of `newdata`?")
  }

  trees <- sort(trees)

  res <- map_df(trees, lightgbm_by_tree,
                object = object, new_data = new_data, type = type)
  res <- dplyr::arrange(res, .row, trees)
  res <- split(res[, -1], res$.row)
  names(res) <- NULL

  tibble::tibble(.pred = res)

}

lightgbm_by_tree <- function(tree, object, new_data, type = NULL) {
  # switch based on prediction type
  if (object$spec$mode == "regression") {
    pred <- predict_lightgbm_regression_numeric(object, new_data, num_iteration = tree)

    pred <- tibble::tibble(.pred = pred)

    nms <- names(pred)
  } else {
    if (type == "class") {
      pred <- predict_lightgbm_classification_class(object, new_data, num_iteration = tree)

      pred <- tibble::tibble(.pred_class = factor(pred, levels = object$lvl))
    } else {
      pred <- predict_lightgbm_classification_prob(object, new_data, num_iteration = tree)

      names(pred) <- paste0(".pred_", names(pred))
    }

    nms <- names(pred)
  }

  pred[["trees"]] <- tree
  pred[[".row"]] <- 1:nrow(new_data)
  pred[, c(".row", "trees", nms)]
}

prepare_df_lgbm <- function(x, y = NULL) {
  categorical_cols <- categorical_columns(x)

  x <- categorical_features_to_int(x, categorical_cols)

  x <- as.matrix(x)

  return(x)
}

categorical_columns <- function(x){
  categorical_cols <- NULL
  for (i in seq_along(x)) {
    if (is.factor(x[[i]])) {
      categorical_cols <- c(categorical_cols, i)
    }
  }
  categorical_cols
}

categorical_features_to_int <- function(x, cat_indices){
  for (i in cat_indices){
    x[[i]] <- as.integer(x[[i]]) -1
  }
  x
}
