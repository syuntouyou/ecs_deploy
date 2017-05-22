require 'timeout'

module EcsDeploy
  class Service
    attr_accessor :cluster, :region, :service_name,:task_definition_name,:revision, :task_definition

    def initialize(
      cluster:, service_name:, task_definition_name: nil, revision: nil,load_balancers: [],
      desired_count: nil, deployment_configuration: {maximum_percent: 200, minimum_healthy_percent: 100},
      region: nil,service_role:,placement_constraints: [],placement_strategy: []
    )
      @cluster = cluster
      @service_roel = service_role
      @service_name = service_name
      @task_definition_name = task_definition_name || service_name
      @desired_count = desired_count
      @placement_constraints = placement_constraints
      @placement_strategy = placement_strategy
      @deployment_configuration = deployment_configuration
      @revision = revision
      load_balancers = [load_balancers] if load_balancers.is_a?(Hash)
      @load_balancers = load_balancers
      @region = region
      @response = nil

    end

    def client
      @client ||= Aws::ECS::Client.new(region: @region)
    end

    def logger
      EcsDeploy.logger
    end

    def current_task_definition_arn
      res = client.describe_services(cluster: @cluster, services: [@service_name])
      res.services[0].task_definition
    end

    def default_service_role
      EcsDeploy.config.ecs_service_role
    end

    def deploy
      res = client.describe_services(cluster: @cluster, services: [@service_name])
      definition = task_definition_name_with_revision
      service_options = {
        cluster: @cluster,
        task_definition: definition,
        deployment_configuration: @deployment_configuration,
      }
      if res.services.empty? || res.services[0].status != 'ACTIVE'
        service_options.merge!({
          service_name:  @service_name,
          desired_count: @desired_count.to_i,
          placement_constraints: @placement_constraints,
          placement_strategy: @placement_strategy,
        })

        if @load_balancers && !@load_balancers.empty?
          service_options.merge!({
            role: @service_role || default_service_role,
            load_balancers: @load_balancers,
          })
        end

        @response = client.create_service(service_options)
        logger.info "create service [#{@service_name}] to [#{definition}] [#{@region}] [#{Paint['OK', :green]}]"
      else
        current_task_definition = res.services[0].task_definition
        current_task_definition = current_task_definition.sub(/\Aarn:aws.*\:task-definition\//,"")
        service_options.merge!({service: @service_name})
        service_options.merge!({desired_count: @desired_count}) if @desired_count
        @response = client.update_service(service_options)
        logger.info "update service [#{@service_name}] from [#{current_task_definition}] to [#{definition}] [#{@region}] [#{Paint['OK', :green]}]"
      end
    end

    def self.display_services(services)
      events = {}
      message = sprintf("| %-30s |%-15s| %-30s | %10s","Name","Running/Desired","TaskDefinition","Deploying")
      EcsDeploy.logger.info message
      message = "-" * 100
      EcsDeploy.logger.info message
      services.group_by { |s| [s.cluster, s.region] }.each do |(cluster, region), ss|
        next if ss.empty?
        client = ss[0].client
        service_names = ss.map(&:service_name)

        res = client.describe_services(cluster: cluster, services: service_names)
        res.services.each do |service|
          # TODO
          # - get revision from task_definition
          # - Get metrics
          task_definition = service.task_definition.sub(/\Aarn:aws.*\:task-definition\//,"")
          name = service.service_name
          counts = sprintf("%5s / %-5s",service.running_count, service.desired_count)
          deploy = service.deployments.size > 1 ? "Yes" : "No"
          message = sprintf("| %-30s | %13s | %-30s | %10s",name,counts,task_definition,deploy)
          EcsDeploy.logger.info message
        end
      end
      message = "-" * 100
      EcsDeploy.logger.info message
    end


    def self.describe_events(client,cluster,service_names,from=Time.now, to_time=nil)
      events = {}
      return events if service_names.empty?
      res = client.describe_services(cluster: cluster, services: service_names)
      res.services.each do |service|
        name = service.service_name
        events[name] = []
        service.events.each  do |event|
          next if event.created_at < from
          next if to_time && event.created_at >= to_time
          events[name] << event
        end
      end
      events
    end

    def self.wait_all_running(services, waiter_options={})
      created_at = Time.now
      services.group_by { |s| [s.cluster, s.region] }.each do |(cl, region), ss|
        next if ss.empty?
        client = ss[0].client
        service_names = ss.map(&:service_name)

        EcsDeploy.logger.info "wait service stable [#{service_names.join(", ")}]"
        client.wait_until(:services_stable, cluster: cl, services: service_names) do |w|
          w.delay        = waiter_options[:delay]        if waiter_options[:delay]
          w.max_attempts = waiter_options[:max_attempts] if waiter_options[:max_attempts]
          w.before_attempt do
            to_time = Time.now
            describe_events(client,cl,service_names,created_at,to_time).each do |name,events|
              events.reverse.each do |event|
                EcsDeploy.logger.info "#{event.message}"
              end
            end
            created_at = to_time
          end
        end
      end
    end

    private

    def task_definition_name_with_revision
      if @revision.to_s.empty? && self.task_definition
        @revision = self.task_definition.revision
      end
      suffix = @revision ? ":#{@revision}" : ""
      "#{@task_definition_name}#{suffix}"
    end
  end
end
