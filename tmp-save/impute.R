################################################################################

#' Imputation
#'
#' Imputation via local XGBoost models.
#'
#' This implementation aims at imputing with good accuracy while being fast.
#' For instance, `nrounds` and `max_depth` are voluntarily chosen low.
#' One could use for example `nrounds = 50` and `max_depth = 5` to improve
#' accuracy a bit, at the expense of computation time.
#' \cr
#' Moreover, `breaks` and `sizes` are used to dynamically choose the number
#' of predictors to use more complex models when there are more missing values.
#' To use only complex models, one could use `breaks = 0` and `sizes = 100`,
#' increasing computation time.
#'
#' @inheritParams bigsnpr-package
#' @param perc.train Percentage of individuals used for the training
#' (the rest is used to assess the error of imputation by SNP).
#' @param nrounds The number of iterations (trees) in
#' [xgboost][xgboost::xgboost]. Default is `20`.
#' @param max_depth maximum depth of a tree. Default is `3`.
#' @param breaks Break points of the number of missing values by SNPs
#' to which we change the number of predictors to be used. The more missing
#' values there are, the more complex is the model used.
#' @param sizes Radius of how many predictors enter the model.
#' @param verbose Print progress? Default is `FALSE`.
#'
#' @return The new [bigSNP] object with a slot `imputation` which is
#' a `data.frame` with 2 columns:
#' - the number of missing values by SNP,
#' - the estimated error of imputation by SNP.
#' @export
#' @import xgboost
#'
#' @examples
snp_impute <- function(x, perc.train = 0.7, nrounds = 20, max_depth = 3,
                       breaks = c(0, trunc(n / c(1000, 200, 100))),
                       sizes = c(10, 20, 30, 50),
                       ncores = 1, verbose = FALSE) {
  check_x(x)
  X <- x$genotypes
  n <- nrow(X)
  n.train <- round(n * perc.train)
  params <- list(max_depth = max_depth)

  estimError <- (perc.train < 1)

  # get descriptors
  X.desc <- describe(X)

  newfile <- checkFile(x, "impute")
  X2 <- deepcopy(X, type = "char",
                 backingfile = paste0(newfile, ".bk"),
                 backingpath = x$backingpath,
                 descriptorfile = paste0(newfile, ".desc"))
  X2.desc <- describe(X2)

  range.chr <- LimsChr(x)

  # function that imputes one chromosome
  if (is.seq <- (ncores == 1)) {
    registerDoSEQ()
  } else {
    cl <- parallel::makeCluster(ncores, outfile = `if`(verbose, "", NULL))
    doParallel::registerDoParallel(cl)
    on.exit(parallel::stopCluster(cl), add = TRUE)
  }
  res <- foreach(ic = seq_len(nrow(range.chr)), .combine = 'rbind') %dopar% {
    lims <- range.chr[ic, ]

    if (verbose)
      printf("Imputing chromosome %d with \"XGBoost\"...\n", lims[3])

    X.part <- sub.big.matrix(X.desc, firstCol = lims[1], lastCol = lims[2])
    X2.part <- sub.big.matrix(X2.desc, firstCol = lims[1], lastCol = lims[2])

    m.part <- ncol(X.part)
    nbNA <- integer(m.part)
    error <- rep(NA_real_, m.part)
    # many different `ind.train` and `ind.val`
    n.rep <- 2 * max(sizes)
    ind.train.rep <- replicate(n.rep, sort(sample(n, n.train)))
    if (estimError) ind.val.rep <-
      apply(ind.train.rep, 2, function(ind) setdiff(seq(n), ind))

    # useful functions
    interval <- function(i, size) {
      ind <- i + -size:size
      ind[ind >= 1 & ind <= m.part & ind != i]
    }
    round2 <- function(pred) (pred > 0.5) + (pred > 1.5)

    opt.save <- options(bigmemory.typecast.warning = FALSE)
    on.exit(options(opt.save), add = TRUE)

    # imputation
    for (i in 1:m.part) {
      # if (!(i %% 10)) print(i)
      X.label <- X.part[, i] * 1
      nbNA[i] <- l <- length(indNA <- which(is.na(X.label)))
      if (l > 0) {
        j <- i %% n.rep + 1
        ind <- setdiff(ind.train.rep[, j], indNA)
        if (estimError) ind.val <- ind.val.rep[, j]

        s <- sizes[max(which(l > breaks))]
        X.data <- X.part[, interval(i, s), drop = FALSE] * 1

        bst <- xgboost(data = X.data[ind, , drop = FALSE],
                       label = X.label[ind],
                       nrounds = nrounds,
                       params = params,
                       nthread = 1,
                       verbose = 0,
                       save_period = NULL)

        pred <- predict(bst, X.data[indNA, , drop = FALSE])
        X2.part[indNA, i] <- round2(pred)
        if (estimError) {
          pred2 <- predict(bst, X.data[ind.val, , drop = FALSE])
          error[i] <- mean(round2(pred2) != X.label[ind.val], na.rm = TRUE)
        }
      }
    }

    if (verbose)
      printf("Done imputing chromosome %d.\n", lims[3])

    data.frame(nbNA, error)
  }

  # create new imputed bigSNP
  snp_list <- list(genotypes = X2,
                   fam = x$fam,
                   map = x$map,
                   imputation = res,
                   backingfile = newfile,
                   backingpath = x$backingpath)
  class(snp_list) <- "bigSNP"
  # save it
  saveRDS(snp_list, file.path(x$backingpath, paste0(newfile, ".rds")))
  # return it
  snp_list
}

################################################################################

#' Title
#'
#' @param x
#' @param nrounds
#' @param max_depth
#' @param breaks
#' @param sizes
#' @param Kfolds
#' @param ncores
#' @param verbose
#'
#' @return
#' @export
#' @import xgboost
#'
#' @examples
snp_imputeCV <- function(x, nrounds = 20, max_depth = 3,
                         breaks = c(0, trunc(n / c(1000, 200, 100))),
                         sizes = c(10, 20, 30, 50),
                         Kfolds = c(2, 3, 5, 8),
                         ncores = 1, verbose = FALSE) {
  check_x(x)
  X <- x$genotypes
  n <- nrow(X)
  params <- list(max_depth = max_depth)

  # get descriptors
  X.desc <- describe(X)

  newfile <- checkFile(x, "impute")
  X2 <- deepcopy(X, type = "char",
                 backingfile = paste0(newfile, ".bk"),
                 backingpath = x$backingpath,
                 descriptorfile = paste0(newfile, ".desc"))
  X2.desc <- describe(X2)

  range.chr <- LimsChr(x)

  # function that imputes one chromosome
  if (is.seq <- (ncores == 1)) {
    registerDoSEQ()
  } else {
    cl <- parallel::makeCluster(ncores, outfile = `if`(verbose, "", NULL))
    doParallel::registerDoParallel(cl)
    on.exit(parallel::stopCluster(cl), add = TRUE)
  }
  res <- foreach(ic = seq_len(nrow(range.chr)), .combine = 'rbind') %dopar% {
    lims <- range.chr[ic, ]

    if (verbose)
      printf("Imputing chromosome %d with \"XGBoost\"...\n", lims[3])

    X.part <- sub.big.matrix(X.desc, firstCol = lims[1], lastCol = lims[2])
    X2.part <- sub.big.matrix(X2.desc, firstCol = lims[1], lastCol = lims[2])

    m.part <- ncol(X.part)
    nbNA <- integer(m.part)
    error <- rep(NA_real_, m.part)

    # useful functions
    interval <- function(i, size) {
      ind <- i + -size:size
      ind[ind >= 1 & ind <= m.part & ind != i]
    }
    round2 <- function(pred) (pred > 0.5) + (pred > 1.5)

    opt.save <- options(bigmemory.typecast.warning = FALSE)
    on.exit(options(opt.save), add = TRUE)

    # imputation
    for (i in 1:m.part) {
      X.label <- X.part[, i] * 1
      nbNA[i] <- l.NA <- length(indNA <- which(is.na(X.label)))
      if (l.NA > 0) {
        w <- max(which(l.NA > breaks))
        ind.col <- interval(i, sizes[w])
        K <- Kfolds[w]

        X.data.noNA <- X.part[-indNA, ind.col, drop = FALSE] * 1
        X.label.noNA <- X.label[-indNA]
        X.data.NA <- X.part[indNA, ind.col, drop = FALSE] * 1

        l.noNA <- nrow(X.data.noNA)
        indCV <- sample(rep_len(1:K, l.noNA))
        preds.NA <- matrix(NA_real_, l.NA, K)
        err <- 0

        for (k in 1:K) {
          ind.val <- which(indCV == k)

          bst <- xgboost(data = X.data.noNA[-ind.val, , drop = FALSE],
                         label = X.label.noNA[-ind.val],
                         nrounds = nrounds,
                         params = params,
                         nthread = 1,
                         verbose = 0,
                         save_period = NULL)

          # validation error
          pred.val <- predict(bst, X.data.noNA[ind.val, , drop = FALSE])
          err <- err + sum(round2(pred.val) != X.label.noNA[ind.val])
          # one vector of predicted values for imputation
          preds.NA[, k] <- predict(bst, X.data.NA)
        }

        # impute by conbining predictions of each fold
        X2.part[indNA, i] <- round2(apply(preds.NA, 1, median))
        # validation error
        error[i] <- err / l.noNA
      }
    }

    if (verbose)
      printf("Done imputing chromosome %d.\n", lims[3])

    data.frame(nbNA, error)
  }

  # create new imputed bigSNP
  snp_list <- list(genotypes = X2,
                   fam = x$fam,
                   map = x$map,
                   imputation = res,
                   backingfile = newfile,
                   backingpath = x$backingpath)
  class(snp_list) <- "bigSNP"
  # save it
  saveRDS(snp_list, file.path(x$backingpath, paste0(newfile, ".rds")))
  # return it
  snp_list
}

################################################################################

#' Title
#'
#' @param x
#' @param nrounds
#' @param max_depth
#'
#' @return
#' @export
#' @import Matrix
#'
#' @examples
snp_imputeCV2 <- function(x, nrounds = 20, max_depth = 3,
                         size = 1000, alpha = 0.1, K = 5,
                         ncores = 1, verbose = FALSE,
                         baseline = FALSE) {
  check_x(x)
  X <- x$genotypes
  n <- nrow(X)
  params <- list(max_depth = max_depth)

  # get descriptors
  X.desc <- describe(X)

  newfile <- checkFile(x, "impute")
  X2 <- deepcopy(X, type = "char",
                 backingfile = paste0(newfile, ".bk"),
                 backingpath = x$backingpath,
                 descriptorfile = paste0(newfile, ".desc"))
  X2.desc <- describe(X2)

  range.chr <- LimsChr(x)

  # function that imputes one chromosome
  if (is.seq <- (ncores == 1)) {
    registerDoSEQ()
  } else {
    cl <- parallel::makeCluster(ncores, outfile = `if`(verbose, "", NULL))
    doParallel::registerDoParallel(cl)
    on.exit(parallel::stopCluster(cl), add = TRUE)
  }
  res <- foreach(ic = seq_len(nrow(range.chr)), .combine = 'rbind') %dopar% {
    lims <- range.chr[ic, ]
    ind.part <- seq2(lims)

    if (verbose)
      printf("Imputing chromosome %d with \"XGBoost\"...\n", lims[3])

    X <- attach.BM(X.desc)
    q.alpha <- stats::qchisq(alpha, df = 1, lower.tail = FALSE)
    corr <- symmpart(corMat(X@address, rowInd = 1:n, colInd = ind.part,
                            size = size, thr = q.alpha / 1:n))

    X2.part <- sub.big.matrix(X2.desc, firstCol = lims[1], lastCol = lims[2])

    m.part <- length(ind.part)
    nbNA <- integer(m.part)
    error <- rep(NA_real_, m.part)

    # useful functions
    interval <- function(i, size) {
      ind <- i + -size:size
      ind[ind >= 1 & ind <= m.part & ind != i]
    }
    round2 <- function(pred) (pred > 0.5) + (pred > 1.5)

    opt.save <- options(bigmemory.typecast.warning = FALSE)
    on.exit(options(opt.save), add = TRUE)

    if (baseline) {
      # first imputation by rounded mean
      baseline <- round2(big_apply(X2.part, a.FUN = function(x, ind) {
        colMeans(x[, ind], na.rm = TRUE)
      }, a.combine = 'c'))
      for (i in 1:m.part) X2.part[which(is.na(X2.part[, i])), i] <- baseline[i]
    }

    # imputation
    for (i in 1:m.part) {
      X.label <- X[, ind.part[i]] * 1
      nbNA[i] <- l.NA <- length(indNA <- which(is.na(X.label)))
      if (l.NA > 0) {
        ind.col <- which(corr[, i] != 0)

        X.data.noNA <- X2.part[-indNA, ind.col, drop = FALSE] * 1
        X.label.noNA <- X.label[-indNA]
        X.data.NA <- X2.part[indNA, ind.col, drop = FALSE] * 1

        l.noNA <- nrow(X.data.noNA)
        indCV <- sample(rep_len(1:K, l.noNA))
        preds.NA <- matrix(NA_real_, l.NA, K)
        err <- 0

        for (k in 1:K) {
          ind.val <- which(indCV == k)

          bst <- xgboost(data = X.data.noNA[-ind.val, , drop = FALSE],
                         label = X.label.noNA[-ind.val],
                         nrounds = nrounds,
                         params = params,
                         nthread = 1,
                         verbose = 0,
                         save_period = NULL)

          # validation error
          pred.val <- predict(bst, X.data.noNA[ind.val, , drop = FALSE])
          err <- err + sum(round2(pred.val) != X.label.noNA[ind.val])
          # one vector of predicted values for imputation
          preds.NA[, k] <- predict(bst, X.data.NA)
        }

        # impute by conbining predictions of each fold
        X2.part[indNA, i] <- round2(apply(preds.NA, 1, median))
        # validation error
        error[i] <- err / l.noNA
      }
    }

    if (verbose)
      printf("Done imputing chromosome %d.\n", lims[3])

    data.frame(nbNA, error)
  }

  # create new imputed bigSNP
  snp_list <- list(genotypes = X2,
                   fam = x$fam,
                   map = x$map,
                   imputation = res,
                   backingfile = newfile,
                   backingpath = x$backingpath)
  class(snp_list) <- "bigSNP"
  # save it
  saveRDS(snp_list, file.path(x$backingpath, paste0(newfile, ".rds")))
  # return it
  snp_list
}

################################################################################
