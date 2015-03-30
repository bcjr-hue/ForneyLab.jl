facts("Marginal calculation integration tests") do
    context("Marginal calculation for two GammaDistributions") do
        @fact calculateMarginal(GammaDistribution(a=1.0, b=2.0), GammaDistribution(a=3.0, b=4.0)) => GammaDistribution(a=3.0, b=6.0)
    end

    context("Marginal calculation for two InverseGammaDistributions") do
        @fact calculateMarginal(InverseGammaDistribution(a=1.0, b=2.0), InverseGammaDistribution(a=3.0, b=4.0)) => InverseGammaDistribution(a=5.0, b=6.0)
    end

    context("Marginal calculation for two GaussianDistributions") do
        @fact calculateMarginal(GaussianDistribution(xi=1.0, W=2.0), GaussianDistribution(xi=3.0, W=4.0)) => GaussianDistribution(xi=4.0, W=6.0)
    end

    context("Marginal calculation for the combination of a Gaussian and student's t-distribution") do
        @fact calculateMarginal(GaussianDistribution(m=0.0, W=1.0), StudentsTDistribution(m=0.0, W=1.0, nu=1.0)) => GaussianDistribution(m=0.0, W=3.0)
        @fact calculateMarginal(StudentsTDistribution(m=0.0, W=1.0, nu=1.0), GaussianDistribution(m=0.0, W=1.0)) => GaussianDistribution(m=0.0, W=3.0)
    end

    context("Marginal calculation for naively factorized GaussianNode") do
        (node, edges) = initializeGaussianNode(y_type=Float64)
        scheme = InferenceScheme()
        factorize!(scheme)
        
        # Presetting marginals
        subgraph1 = subgraph(scheme, edges[1])
        scheme.approximate_marginals[(node, subgraph1)] = GaussianDistribution()
        subgraph2 = subgraph(scheme, edges[2])
        scheme.approximate_marginals[(node, subgraph2)] = GammaDistribution()
        subgraph3 = subgraph(scheme, edges[3])
        scheme.approximate_marginals[(node, subgraph3)] = GaussianDistribution()
        
        # Univariate marginal
        calculateMarginal!(node, subgraph1, scheme)
        @fact scheme.approximate_marginals[(node, subgraph1)] => GaussianDistribution(W=2.0, xi=0.0)
        # Univariate marginal
        calculateMarginal!(node, subgraph2, scheme)
        @fact scheme.approximate_marginals[(node, subgraph2)] => GammaDistribution(a=1.0, b=2.0)
        # Univariate marginal
        calculateMarginal!(node, subgraph3, scheme)
        @fact scheme.approximate_marginals[(node, subgraph3)] => GaussianDistribution(m=1.0, V=tiny())
    end
    
    context("Marginal calculation for the structurally factorized GaussianNode") do
        (node, edges) = initializeGaussianNode(y_type=GaussianDistribution)
        scheme = InferenceScheme()
        factorize!(Set{Edge}([edges[3]]))
        
        # Presetting marginals
        scheme.approximate_marginals[(node, scheme.factorization[1])] = NormalGammaDistribution()
        scheme.approximate_marginals[(node, scheme.factorization[2])] = GaussianDistribution()
        
        # Joint marginal
        subgraph = scheme.factorization[1]
        calculateMarginal!(node, subgraph, scheme)
        @fact scheme.approximate_marginals[(node, subgraph)] => NormalGammaDistribution(m=0.0, beta=huge(), a=1.5, b=1.5)
        # Univariate marginal
        subgraph = scheme.factorization[2]
        calculateMarginal!(node, subgraph, scheme)
        @fact scheme.approximate_marginals[(node, subgraph)] => GaussianDistribution(W=2.0, xi=0.0)
    end
end