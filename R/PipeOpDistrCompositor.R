#' @title PipeOpDistrCompositor
#'
#' @usage NULL
#' @name mlr_pipeops_distrcompose
#' @format [`R6Class`] inheriting from [`PipeOp`].
#'
#' @description
#' Estimate a survival distribution from an `lp` or `crank` predicted in a [PredictionSurv].
#'
#' Note:
#' * This compositor is only sensible if assuming a linear model form, which may not always be the case.
#' * Currently only discrete estimators, Kaplan-Meier and Nelson-Aalen, are implemented. Resulting in a
#' predicted `[distr6::WeightedDiscrete]` distribution for each individual, in the future we plan to
#' extend this to allow continuous estimators.
#'
#' @section Construction:
#' ```
#' PipeOpDistrCompositor$new(id = "distrcompose", param_vals = list())
#' ```
#' * `id` :: `character(1)` \cr
#'   Identifier of the resulting  object, default `"distrcompose"`.
#' * `param_vals` :: named `list` \cr
#'   List of hyperparameter settings, overwriting the hyperparameter settings that would otherwise be set during construction. Default `list()`.
#'
#' @section Input and Output Channels:
#' [PipeOpDistrCompositor] has two input channels, "base" and "pred". Both input channels take
#' `NULL` during training and [PredictionSurv] during prediction.
#'
#' [PipeOpDistrCompositor] has one output channel named "output", producing `NULL` during training
#' and a [PredictionSurv] during prediction.
#'
#' The output during prediction is the [PredictionSurv] from the "pred" input but with an extra (or overwritten)
#' column for `distr` predict type; which is composed from the `distr` of "base" and `lp` or `crank`
#' of "pred".
#'
#' @section State:
#' The `$state` is left empty (`list()`).
#'
#' @section Parameters:
#' The parameters are:
#' * `form` :: `character(1)` \cr
#'    Determines the form that the predicted linear survival model should take. This is either,
#'    accelerated-failure time, `aft`, proportional hazards, `ph`, or proportional odds, `po`.
#'    Default `aft`.
#' * `overwrite` :: `logical(1)` \cr
#'    If `FALSE` (default) then if the "pred" input already has a `distr`, the compositor does nothing
#'    and returns the given [PredictionSurv]. If `TRUE` then the `distr` is overwritten with the `distr`
#'    composed from `lp`/`crank` - this is useful for changing the prediction `distr` from one model
#'    form to another.
#'
#' @section Internals:
#' The respective `form`s above have respective survival distributions:
#'    \deqn{aft: S(t) = S0(t/exp(lp))}
#'    \deqn{ph: S(t) = S0(t)^exp(lp)}
#'    \deqn{po: S(t) = S0 * [exp(-lp) + (1-exp(-lp))*S0(t)]^-1}
#' where \eqn{S0} is the estimated baseline survival distribution, and `lp` is the predicted
#' linear predictor. If the input model does not predict a linear predictor then `crank` is
#' assumed to be the `lp` - **this may be a strong and unreasonable assumption.**
#'
#' @section Fields:
#' Only fields inherited from [PipeOp].
#'
#' @section Methods:
#' Only methods inherited from [PipeOp].
#'
#' @seealso [mlr3pipelines::PipeOp] and [distrcompositor]
#' @export
#' @family survival compositors
#' @examples
#' library("mlr3")
#' library("mlr3pipelines")
#' set.seed(42)
#'
#' # Three methods to transform the cox ph predicted `distr` to an
#' #  accelerated failure time model
#' task = tsk("rats")
#'
#' # Method 1 - Train and predict separately then compose
#' base = lrn("surv.kaplan")$train(task)$predict(task)
#' pred = lrn("surv.coxph")$train(task)$predict(task)
#' pod = po("distrcompose", param_vals = list(form = "aft", overwrite = TRUE))
#' pod$predict(list(base = base, pred = pred))
#'
#' # Method 2 - Create a graph manually
#' gr = Graph$new()$
#'   add_pipeop(po("learner", lrn("surv.kaplan")))$
#'   add_pipeop(po("learner", lrn("surv.glmnet")))$
#'   add_pipeop(po("distrcompose"))$
#'   add_edge("surv.kaplan", "distrcompose", dst_channel = "base")$
#'   add_edge("surv.glmnet", "distrcompose", dst_channel = "pred")
#' gr$train(task)
#' gr$predict(task)
#'
#' # Method 3 - Syntactic sugar: Wrap the learner in a graph
#' cvglm.distr = distrcompositor(learner = lrn("surv.cvglmnet"),
#'                             estimator = "kaplan",
#'                             form = "aft")
#' resample(task, cvglm.distr, rsmp("cv", folds = 2))$predictions()
PipeOpDistrCompositor = R6Class("PipeOpDistrCompositor",
  inherit = PipeOp,
  public = list(
    initialize = function(id = "distrcompose", param_vals = list(form = "aft", overwrite = FALSE)) {
      super$initialize(id = id,
                       param_set = ParamSet$new(params = list(
                         ParamFct$new("form", default = "aft", levels = c("aft","ph","po"), tags = c("predict")),
                         ParamLgl$new("overwrite", default = FALSE, tags = c("predict"))
                       )),
                       param_vals = param_vals,
                       input = data.table(name = c("base","pred"), train = "NULL", predict = "PredictionSurv"),
                       output = data.table(name = "output", train = "NULL", predict = "PredictionSurv"),
                       packages = "distr6")
      },

    train_internal = function(inputs) {
      self$state = list()
      list(NULL)
      },

    predict_internal = function(inputs) {
      base = inputs$base
      inpred = inputs$pred

      overwrite = self$param_set$values$overwrite

      if ("distr" %in% inpred$predict_types & !overwrite) {
        return(list(inpred))
      } else {
        assert("distr" %in% base$predict_types)

        row_ids = inpred$row_ids
        truth = inpred$truth
        map(inputs, function(x) assert_true(identical(row_ids, x$row_ids)))
        map(inputs, function(x) assert_true(identical(truth, x$truth)))

        # get form, set default if missing
        form = self$param_set$values$form

        base = base$distr[1]
        times = base$support()$elements()

        nr = nrow(inpred$data$tab)
        nc = length(times)

        if(is.null(inpred$lp) | length(inpred$lp) == 0)
          lp = inpred$crank
        else
          lp = inpred$lp

        timesmat = matrix(times, nrow = nr, ncol = nc, byrow = T)
        survmat = matrix(base$survival(times), nrow = nr, ncol = nc, byrow = T)
        lpmat = matrix(lp, nrow = nr, ncol = nc)

        if(form == "ph")
          cdf = 1 - (survmat ^ exp(lpmat))
        else if (form == "aft")
          cdf = t(apply(timesmat / exp(lpmat), 1, function(x) base$cdf(x)))
        else if (form == "po")
          cdf = 1 - (survmat * ({exp(-lpmat) + ((1 - exp(-lpmat)) * survmat)}^-1))

        x = rep(list(data = data.frame(x = times, cdf = 0)), nr)

        for(i in 1:nc)
          x[[i]]$cdf = cdf[i,]

        distr = distr6::VectorDistribution$new(distribution = "WeightedDiscrete", params = x,
                                               decorators = c("CoreStatistics", "ExoticStatistics"))

        if(is.null(inpred$crank) | length(inpred$crank) == 0)
          crank = lp
        else
          crank = inpred$crank

        if(is.null(inpred$lp) | length(inpred$lp) == 0)
          lp = NULL
        else
          lp = inpred$lp

        return(list(PredictionSurv$new(row_ids = row_ids, truth = truth,
                                       crank = crank, distr = distr, lp = lp)))
      }
    }
  )
)