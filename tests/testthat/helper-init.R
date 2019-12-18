################################################################################

library(testthat)
library(bigsnpr)
library(bigparallelr)

################################################################################

options(bigstatsr.check.parallel.blas = FALSE)

################################################################################

# https://github.com/hadley/testthat/issues/567
Sys.unsetenv("R_TESTS")

not_cran <- identical(Sys.getenv("BIGSNPR_CRAN"), "false")
NCORES <- `if`(not_cran && (parallel::detectCores() > 2), 2, 1)

################################################################################