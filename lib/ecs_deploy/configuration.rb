module EcsDeploy
  class Configuration
    attr_accessor \
      :log_level,
      :access_key_id,
      :secret_access_key,
      :default_region,
      :ecs_service_role
      :max_attempts

    def initialize
      @log_level = :info
      @ecs_service_role = "ecsServiceRole"
    end
  end
end
