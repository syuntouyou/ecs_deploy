module ECS
  class Strategy
    attr_reader :context,:namespace,:region

    def initialize(context,region,namespace)
      @context = context
      @region = region
      @namespace = namespace
    end

    def fetch(key,options={})
      context.fetch(fetch_key(key),options) || context.fetch("ecs_#{key}",options)
    end

    def fetch_key(key)
      namespace ?  :"#{namespace}_#{key}" : key
    end

    def task_definitions
      return  @task_definitions if @task_definitions
      return [] unless fetch(:tasks)
      task_definitions = []
      fetch(:tasks).map do |t|
        task_definition = EcsDeploy::TaskDefinition.new(
          region: region,
          task_definition_name:  t[:name],
          container_definitions: t[:container_definitions],
          task_role_arn:         t[:task_role_arn],
          network_mode:          t[:network_mode],
          volumes:               t[:volumes],
          executions:            t[:executions],
          placement_constraints: t[:placement_constraints],
          requires_compatibilities: t[:requires_compatibilities],
          execution_role_arn:    t[:execution_role_arn],
          cpu:                   t[:cpu],
          memory:                t[:memory],
        )
        task_definitions << task_definition
      end
      @task_definitions = task_definitions
    end

    def is_target_cluster?(cluster)
      if fetch(:target_cluster) && fetch(:target_cluster).size > 0
         return false unless fetch(:target_cluster).include?(cluster)
      end
      true
    end

    def get_task_definition_for(task_definition_name)
      task_definitions.find{|t| t.task_definition_name == task_definition_name}
    end

    def is_target_task_definition_name?(task_definition_name)
      if fetch(:target_task_definition) && fetch(:target_task_definition).size > 0
        return unless fetch(:target_task_definition).include?(service[:task_definition_name])
      end
      true
    end

    def default_cluster
      context.fetch(:ecs_default_cluster)
    end

    def rollback_task_definition_arns(service,current_task_definition_arn, rollback_step)
      task_definition = task_definition_for(service)
      task_definition.rollback_task_definition_arns(current_task_definition_arn, rollback_step)
    end

    def rollback
      rollback_routes = {}
      rollback_step = (ENV["STEP"] || 1).to_i

      services.each do |service|
        current_task_definition_arn = service.current_task_definition_arn
        rollback_arns = self.rollback_task_definition_arns(service,current_task_definition_arn, rollback_step)

        raise "Past task_definition_arns is nothing" if rollback_arns.empty?
        rollback_arn = rollback_arns.pop

        logger.info "#{current_task_definition_arn} -> #{rollback_arn}"

        service.task_definition_name =  rollback_arn
        service.deploy
      end
      waiter_options = EcsDeploy.config.service_waiter_options
      EcsDeploy::Service.wait_all_running(services, waiter_options)
      self.deregister_newer_task_definision
    end

    def task_definition_for(service)
      task_definition = self.task_definitions.find do |t|
        t.task_definition_name == service.task_definition_name  || t.task_definition_name == service.service_name
      end
    end


    def newer_task_definition_arns(service,current_task_definition_arn)
      task_definition = task_definition_for(service)
      task_definition.newer_task_definition_arns(current_task_definition_arn)
    end

    def deregister_newer_task_definision
      services.each do |service|
        current_task_definition_arn = service.current_task_definition_arn
        newer_arns = self.newer_task_definition_arns(service,current_task_definition_arn)
        next if newer_arns.empty?
        logger.info "#{newer_arns.join(",")} will be removed."
        newer_arns.each do |task_definition_arn|
          EcsDeploy::TaskDefinition.deregister(task_definition_arn, region)
        end
      end
    end


    def logger
      EcsDeploy.logger
    end

    def services
      @services ||= fetch(:services).map do |service|

        next unless is_target_cluster?(service[:cluster])
        next unless is_target_task_definition_name?(service[:task_definition_name])

        service_options = {
          region:                region,
          cluster:               service[:cluster] || default_cluster,
          name:                  service[:name],
          service_role:          service[:service_role],
          task_definition_name:  service[:task_definition_name],
          load_balancers:        service[:load_balancers],
          desired_count:         service[:desired_count],
          launch_type:           service[:launch_type],
          placement_constraints: service[:placement_constraints],
          placement_strategy:    service[:placement_strategy],
          force_new_deployment:  service[:force_new_deployment],
          health_check_grace_period_seconds: service[:health_check_grace_period_seconds],
        }

        service_options[:deployment_configuration] = service[:deployment_configuration] if service[:deployment_configuration]
        s = EcsDeploy::Service.new(**service_options)
        s.task_definition = get_task_definition_for(service[:task_definition_name])
        s
      end.compact
    end

    def deploy
      self.services.each do |service|
        service.deploy
      end
      waiter_options = EcsDeploy.config.service_waiter_options
      EcsDeploy::Service.wait_all_running(services, waiter_options)
    end

    def display_service_status
      EcsDeploy::Service.display_services(services)
    end

    def run
      task_definitions.each do |task_definition|
        task_definition.executions.each do |exec|
          exec[:cluster] ||= default_cluster
          task_definition.run(exec)
        end
      end
    end

    def register_run_task_definition
      task_definitions.each do |task_definition|
        next unless task_definition.has_execution?
        task_definition.register
      end
    end

    def register_task_definition
      task_definitions.each do |task_definition|
        next if task_definition.registered?
        task_definition.register
      end
    end
  end
end

