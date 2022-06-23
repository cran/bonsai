## ---- include = FALSE---------------------------------------------------------
knitr::opts_chunk$set(
  collapse = TRUE,
  comment = "#>"
)

if (rlang::is_installed("partykit") && 
    rlang::is_installed("lightgbm") &&
    rlang::is_installed("modeldata")) {
  run <- TRUE
} else {
  run <- FALSE
}

knitr::opts_chunk$set(
  eval = run
)

## ----setup--------------------------------------------------------------------
library(bonsai)

## -----------------------------------------------------------------------------
library(modeldata)

data(penguins)

str(penguins)

## -----------------------------------------------------------------------------
# set seed for reproducibility
set.seed(1)

# specify and fit model
dt_mod <- 
  decision_tree() %>%
  set_engine(engine = "rpart") %>%
  set_mode(mode = "classification") %>%
  fit(
    formula = species ~ flipper_length_mm + island, 
    data = penguins
  )

dt_mod

## -----------------------------------------------------------------------------
decision_tree() %>%
  set_engine(engine = "partykit") %>%
  set_mode(mode = "classification") %>%
  fit(
    formula = species ~ flipper_length_mm + island, 
    data = penguins
  )

## -----------------------------------------------------------------------------
rf_mod <- 
  rand_forest() %>%
  set_engine(engine = "partykit") %>%
  set_mode(mode = "classification") %>%
  fit(
    formula = species ~ flipper_length_mm + island, 
    data = penguins
  )

## -----------------------------------------------------------------------------
bt_mod <- 
  boost_tree() %>%
  set_engine(engine = "lightgbm") %>%
  set_mode(mode = "classification") %>%
  fit(
    formula = species ~ flipper_length_mm + island, 
    data = penguins
  )

bt_mod

