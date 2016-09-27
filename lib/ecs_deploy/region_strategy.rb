module ECS
  class RegionStrategy
    attr_reader :regions,:context,:namespace

    def initialize(context,namespace)
      @context = context
      @strategies = {}
      @namespace = namespace
      @regions = Array(fetch(:region))
      @regions = [default_region] if @regions.empty?
    end

    def default_region
      EcsDeploy.config.default_region || ENV["AWS_DEFAULT_REGION"]
    end

    def fetch_key(key)
      namespace ?  :"#{namespace}_#{key}" : key
    end

    def fetch(key,options={})
      context.fetch(fetch_key(key),options) || context.fetch("ecs_#{key}",options)
    end

    def strategy_for(region)
      @strategies[region] ||= ECS::Strategy.new(context,region,namespace)
    end

    def rollback
      regions.each do |region|
        strategy_for(region).rollback
      end
    end

    def deploy
      regions.each do |region|
        strategy_for(region).deploy
      end
    end

    def run
      regions.each do |region|
        strategy_for(region).run
      end
    end

    def register_run_task_definition
      regions.each do |region|
        strategy_for(region).register_run_task_definition
      end
    end

    def register_task_definition
      regions.each do |region|
        strategy_for(region).register_task_definition
      end
    end
  end
end
