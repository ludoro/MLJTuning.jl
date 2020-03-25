mutable struct Explicit <: TuningStrategy end 

# models! returns all available models in the range at once:
function MLJTuning.models!(tuning::Explicit,
                           model,
                           history,
                           state,
                           n_remaining,
                           verbosity)
    return state[_length(history) + 1:end] # _length(nothing) = 0
end

