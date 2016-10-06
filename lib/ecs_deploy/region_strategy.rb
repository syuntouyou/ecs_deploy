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
      named_fetch(key,options) || context.fetch("ecs_#{key}",options)
    end

    def named_fetch(key,options={})
      context.fetch(fetch_key(key),options)
    end

    def named_set(key,value)
      context.set(fetch_key(key),value)
    end

    def logger
        EcsDeploy.logger
    end

    def set_revision
      if named_fetch(:sha1) && named_fetch(:repo_url)
        git_command = "git ls-remote #{fetch(:repo_url)} #{fetch(:branch)}"
        logger.info git_command
        result = `#{git_command}`
        revision = result.split("\t")[0]
        if !revision && revision == ""
          raise "can not get revision"
        end
        named_set(:sha1,revision)
      end
      logger.info "current_revision: #{named_fetch(:sha1)}"
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
