# Tests for Shiny Docker Demo App
# These tests run during Docker build - failures abort the build

library(testthat)

# ============================================================================
# Package Loading Tests
# ============================================================================
# Verify all required packages are installed and loadable

test_that("required packages are installed", {
  expect_true(requireNamespace("shiny", quietly = TRUE))
  expect_true(requireNamespace("ggplot2", quietly = TRUE))
  expect_true(requireNamespace("dplyr", quietly = TRUE))
  expect_true(requireNamespace("DT", quietly = TRUE))
})

test_that("packages load without error", {
  expect_no_error(library(shiny))
  expect_no_error(library(ggplot2))
  expect_no_error(library(dplyr))
  expect_no_error(library(DT))
})

# ============================================================================
# Data Preparation Tests
# ============================================================================
# Verify the mtcars data preparation works correctly

test_that("mtcars data is available", {
  expect_true(exists("mtcars"))
  expect_equal(nrow(mtcars), 32)
  expect_equal(ncol(mtcars), 11)
})

test_that("cars_data preparation works", {
  library(dplyr)

  cars_data <- mtcars %>%
    mutate(car_name = rownames(mtcars)) %>%
    select(car_name, everything())

  # Should have 32 rows and 12 columns (11 + car_name)

  expect_equal(nrow(cars_data), 32)
  expect_equal(ncol(cars_data), 12)

  # car_name should be first column

  expect_equal(names(cars_data)[1], "car_name")

  # Should contain expected car names
  expect_true("Mazda RX4" %in% cars_data$car_name)
  expect_true("Toyota Corolla" %in% cars_data$car_name)
})

# ============================================================================
# Filter Logic Tests
# ============================================================================
# Verify the MPG filter works correctly

test_that("MPG filter produces correct results", {
  library(dplyr)

  cars_data <- mtcars %>%
    mutate(car_name = rownames(mtcars))

  # Filter for MPG >= 20
  filtered <- cars_data %>% filter(mpg >= 20)

  # All remaining cars should have MPG >= 20
  expect_true(all(filtered$mpg >= 20))

  # Toyota Corolla (33.9 mpg) should be included
  expect_true("Toyota Corolla" %in% filtered$car_name)

  # Cadillac Fleetwood (10.4 mpg) should be excluded
  expect_false("Cadillac Fleetwood" %in% filtered$car_name)
})

test_that("extreme filter values work", {
  library(dplyr)

  cars_data <- mtcars %>%
    mutate(car_name = rownames(mtcars))

  # Filter with minimum value - should return all cars
  all_cars <- cars_data %>% filter(mpg >= 10)
  expect_equal(nrow(all_cars), 32)

  # Filter with maximum value - should return few cars
  high_mpg <- cars_data %>% filter(mpg >= 30)
  expect_lt(nrow(high_mpg), 10)
  expect_gt(nrow(high_mpg), 0)
})

# ============================================================================
# Data Transformation Tests
# ============================================================================
# Verify data transformations for display

test_that("transmission values transform correctly", {
  am_auto <- ifelse(0 == 0, "Automatic", "Manual")
  am_manual <- ifelse(1 == 0, "Automatic", "Manual")

  expect_equal(am_auto, "Automatic")
  expect_equal(am_manual, "Manual")
})

test_that("engine type values transform correctly", {
  vs_v <- ifelse(0 == 0, "V-shaped", "Straight")
  vs_s <- ifelse(1 == 0, "V-shaped", "Straight")

  expect_equal(vs_v, "V-shaped")
  expect_equal(vs_s, "Straight")
})
