using Distributed

using Test

@everywhere begin
    using MLJBase
    using MLJTuning
    using ..Models
    import ComputationalResources: CPU1, CPUProcesses, CPUThreads
end

using Random
Random.seed!(1234*myid())
using .TestUtilities

N = 30
x1 = rand(N);
x2 = rand(N);
x3 = rand(N);
X = (x1=x1, x2=x2, x3=x3);
y = 2*x1 .+ 5*x2 .- 3*x3 .+ 0.4*rand(N);

m(K) = KNNRegressor(K=K)
r = [m(K) for K in 2:13]

# TODO: replace the above with the line below and post an issue on
# the failure (a bug in Distributed, I reckon):
# r = (m(K) for K in 2:13)

@testset "constructor" begin
    @test_throws ErrorException TunedModel(model=first(r), tuning=Explicit(),
                                           measure=rms)
    @test_throws ErrorException TunedModel(tuning=Explicit(),
                                           range=r, measure=rms)
    @test_throws ErrorException TunedModel(model=42, tuning=Explicit(),
                                           range=r, measure=rms)
    @test_logs((:info, r"No measure"),
               TunedModel(model=first(r), tuning=Explicit(), range=r))
end

# @testset "duplicate models warning" begin
#     s = [m(K) for K in 2:13]
#     push!(s, m(13))
#     tm = TunedModel(model=first(s), tuning=Explicit(),
#                     range=s, resampling=CV(nfolds=2),
#                     measures=[rms, l1])
#     @test_logs((:info, r"Attempting"),
#                (:warn, r"A model already"),
#                fitresult, meta_state, report = fit(tm, 1, X, y))
#     history, _, state = meta_state;
#     @test length(history) == length(2:13) + 1
# end

results = [(evaluate(model, X, y,
                     resampling=CV(nfolds=2),
                     measure=rms,
                     verbosity=0,)).measurement[1] for model in r]

@testset "measure compatibility check" begin
    tm = TunedModel(model=first(r), tuning=Explicit(),
                    range=r, resampling=CV(nfolds=2),
                    measures=cross_entropy)
    @test_throws ArgumentError fit(tm, 0, X, y)
end

@testset_accelerated "basic fit (CPU1)" accel begin
    printstyled("\n Testing progressmeter basic fit with $(accel) and CPU1 resampling \n", color=:bold)
    best_index = argmin(results)
    tm = TunedModel(model=first(r), tuning=Explicit(),
                    range=r, resampling=CV(nfolds=2),
                    measures=[rms, l1], acceleration=accel)
    fitresult, meta_state, report = fit(tm, 1, X, y);
    history, _, state = meta_state;
    results2 = map(event -> event.measurement[1], history)
    @test results2 ≈ results
    @test fitresult.model == collect(r)[best_index]
    @test report.best_model == collect(r)[best_index]
    @test report.history[5] == MLJTuning.delete(history[5], :metadata)
end

@static if VERSION >= v"1.3.0-DEV.573"
@testset_accelerated "Basic fit (CPUThreads)" accel begin
    printstyled("\n Testing progressmeter basic fit with $(accel) and CPUThreads resampling \n", color=:bold)
    tm = TunedModel(model=first(r), tuning=Explicit(),
                    range=r, resampling=CV(nfolds=2),
                    measures=[rms, l1], acceleration= CPUThreads(),
                    acceleration_resampling=accel)
    fitresult, meta_state, report = fit(tm, 1, X, y);
    history, _, state = meta_state;
    results3 = map(event -> event.measurement[1], history)
    @test results3 ≈ results
end
end
@testset_accelerated "Basic fit (CPUProcesses)" accel begin
    printstyled("\n Testing progressmeter basic fit with $(accel) and CPUProcesses resampling \n", color=:bold)
    best_index = argmin(results)
    tm = TunedModel(model=first(r), tuning=Explicit(),
                    range=r, resampling=CV(nfolds=2),
                    measures=[rms, l1], acceleration=CPUProcesses(),
                    acceleration_resampling=accel)
    fitresult, meta_state, report = fit(tm, 1, X, y);
    history, _, state = meta_state;
    results4 = map(event -> event.measurement[1], history)
    @test results4 ≈ results
end

@testset_accelerated("under/over supply of models", accel, begin
                     tm = TunedModel(model=first(r), tuning=Explicit(),
                                     range=r, measures=[rms, l1],
                                     acceleration=accel,
                                     resampling=CV(nfolds=2),
                                     n=4)
    mach = machine(tm, X, y)
    fit!(mach, verbosity=1)
    history = MLJBase.report(mach).history
    @test map(event -> event.measurement[1], history) ≈ results[1:4]

    tm.n=100
    @test_logs (:info, r"Only 12") fit!(mach, verbosity=0)
    history = MLJBase.report(mach).history
    @test map(event -> event.measurement[1], history) ≈ results
end)

@everywhere begin

    # variation of the Explicit strategy that annotates the models
    # with metadata
    mutable struct MockExplicit <: MLJTuning.TuningStrategy end

    annotate(model) = (model, params(model)[1])

    _length(x) = length(x)
    _length(::Nothing) = 0
    MLJTuning.models(tuning::MockExplicit,
                     model,
                     history,
                     state,
                     n_remaining,
                     verbosity) =
                         annotate.(state)[_length(history) + 1:end], state

    function default_n(tuning::Explicit, range)
        try
            length(range)
        catch MethodError
            DEFAULT_N
        end

    end

end

@testset_accelerated("passing of model metadata", accel,
                  begin
                     tm = TunedModel(model=first(r), tuning=MockExplicit(),
                                     range=r, resampling=CV(nfolds=2),
                                     measures=[rms, l1], acceleration=accel)
                     fitresult, meta_state, report = fit(tm, 0, X, y);
                     history, _, state = meta_state;
                     @test all(history) do event
                         event.metadata == event.model.K
                     end
end)

true
