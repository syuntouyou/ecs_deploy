require 'timeout'

module EcsDeploy
  class Service
    attr_accessor :cluster, :region, :service_name,:task_definition_name,:revision

    def initialize(
      cluster:, service_name:, task_definition_name: nil, revision: nil,load_balancers: [],
      desired_count: nil, deployment_configuration: {maximum_percent: 200, minimum_healthy_percent: 100},
      region: nil,service_role:
    )
      @cluster = cluster
      @service_roel = service_role
      @service_name = service_name
      @task_definition_name = task_definition_name || service_name
      @desired_count = desired_count
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
      service_options = {
        cluster: @cluster,
        task_definition: task_definition_name_with_revision,
        deployment_configuration: @deployment_configuration,
      }
      if res.services.empty?
        service_options.merge!({
          service_name:  @service_name,
          desired_count: @desired_count.to_i,
        })

        if @load_balancers && !@load_balancers.empty?
          service_options.merge!({
            role: @service_role || default_service_role,
            load_balancers: @load_balancers,
          })
        end

        @response = client.create_service(service_options)
        logger.info "create service [#{@service_name}] [#{@region}] [#{Paint['OK', :green]}]"
      else
        service_options.merge!({service: @service_name})
        service_options.merge!({desired_count: @desired_count}) if @desired_count
        @response = client.update_service(service_options)
        logger.info "update service [#{@service_name}] [#{@region}] [#{Paint['OK', :green]}]"
      end
    end

    def self.wait_all_running(services)
      services.group_by { |s| [s.cluster, s.region] }.each do |(cl, region), ss|
        next if ss.empty?
        client = ss[0].client
        service_names = ss.map(&:service_name)

        client.wait_until(:services_stable, cluster: cl, services: service_names) do |w|
          w.before_attempt do
            EcsDeploy.logger.info "wait service stable [#{service_names.join(", ")}]"
          end
        end
      end
    end

    private

    def task_definition_name_with_revision
      suffix = @revision ? ":#{@revision}" : ""
      "#{@task_definition_name}#{suffix}"
    end
  end
end
