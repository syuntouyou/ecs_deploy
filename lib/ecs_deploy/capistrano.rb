require 'ecs_deploy'

def define_ecs_deploy_task(name)
  Module.new do
    extend Rake::DSL
    extend self
    @name = name
    namespace name do
      def self::region_strategy
        @region_strategy ||= ECS::RegionStrategy.new(self,@name)
      end

      task set_revision: ["ecs:configure"]  do
        region_strategy.set_revision
      end

      desc "Register Task Definition"
      task register_task_definition: ["#{name}:set_revision"] do
        region_strategy.register_task_definition
      end

      desc "Run"
      task run_executions: [:register_run_task_definition] do
        region_strategy.run
      end

      task register_run_task_definition:  ["#{name}:set_revision"]do
        region_strategy.register_run_task_definition
      end

      namespace :deploy do
        desc "deploy with rake run"
        task :migrations do
          set :migrate, true
          invoke "#{@name}:deploy"
        end
      end

      desc "Deploy"
      task deploy:  ["#{name}:set_revision"] do
        invoke "#{@name}:run_executions"
        invoke "#{@name}:register_task_definition"
        region_strategy.deploy
      end

      desc "Rollback"
      task rollback: ["ecs:configure"] do
        region_strategy.rollback
      end
    end
  end
end

namespace :ecs do
  task :configure do
    EcsDeploy.configure do |c|
      c.log_level           = fetch(:ecs_log_level)           if fetch(:ecs_log_level)
      c.ecs_service_role    = fetch(:ecs_service_role)        if fetch(:ecs_service_role)
      c.default_region      = Array(fetch(:ecs_region))[0]    if fetch(:ecs_region)
    end

    if ENV["TARGET_CLUSTER"]
      set :target_cluster, ENV["TARGET_CLUSTER"].split(",").map(&:strip)
    end
    if ENV["TARGET_TASK_DEFINITION"]
      set :target_task_definition, ENV["TARGET_TASK_DEFINITION"].split(",").map(&:strip)
    end
  end

end

define_ecs_deploy_task :ecs
