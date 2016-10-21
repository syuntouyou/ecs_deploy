module EcsDeploy
  class TaskDefinition

    attr_reader :task_definition_name,:task_role_arn
    def self.deregister(arn, region)
      client = Aws::ECS::Client.new(region: region)
      client.deregister_task_definition({
        task_definition: arn,
      })
      EcsDeploy.logger.info "deregister task definition [#{arn}] [#{region}] [#{Paint['OK', :green]}]"
    end

    def logger
      EcsDeploy.logger
    end

    def clean
    end


    def initialize(
      task_definition_name:,
      region: nil,
      network_mode: nil,
      volumes: [], container_definitions: [],
      task_role_arn: nil,
      executions: []
    )
      @task_definition_name = task_definition_name
      @task_role_arn        = task_role_arn
      @network_mode         = network_mode
      @region               = region
      @executions           = executions

      @container_definitions = container_definitions.map do |cd|
        if cd[:docker_labels]
          cd[:docker_labels] = cd[:docker_labels].map { |k, v| [k.to_s, v] }.to_h
        end
        if cd[:log_configuration] && cd[:log_configuration][:options]
          cd[:log_configuration][:options] = cd[:log_configuration][:options].map { |k, v| [k.to_s, v] }.to_h
        end
        cd
      end
      @volumes = volumes
      @awslog_clients = {}
    end

    def registered?
      @registered
    end

    def executions
      Array(@executions)
    end

    def client
      @client ||= ::Aws::ECS::Client.new(region: @region)
    end

    def has_execution?
      !executions.empty?
    end

    def wait_until(waiter_name,options={},waiter_options={})
      client.wait_until(waiter_name, options) do |w|
        w.delay        = waiter_options[:delay]        if waiter_options[:delay]
        w.max_attempts = waiter_options[:max_attempts] if waiter_options[:max_attempts]
      end
    end

    def newer_task_definition_arns(current_task_definition_arn)
      task_definition_arns = self.recent_task_definition_arns

      current_arn_index = task_definition_arns.index do |arn|
        arn == current_task_definition_arn
      end
      return [] unless current_arn_index

      task_definition_arns[0...current_arn_index]
    end


    def rollback_task_definition_arns(current_task_definition_arn,rollback_step)

      task_definition_arns = self.recent_task_definition_arns

      current_arn_index = task_definition_arns.index do |arn|
        arn == current_task_definition_arn
      end

      rollback_arn_index = current_arn_index + rollback_step
      task_definition_arns[current_arn_index...rollback_arn_index]
    end


    def recent_task_definition_arns
      resp = client.list_task_definitions(
        family_prefix: @task_definition_name,
        sort: "DESC"
      )
      resp.task_definition_arns
    rescue
      []
    end

    def register
      client.register_task_definition({
        family: @task_definition_name,
        container_definitions: @container_definitions,
        volumes: @volumes,
        task_role_arn: @task_role_arn,
        network_mode: @network_mode,
      })
      logger.info "register task definition [#{@task_definition_name}] [#{@region}] [#{Paint['OK', :green]}]"
      @registered = true
    end

    def has_stream_prefix?(name)
      options = awslogs_options_for(name)
      options["awslogs-stream-prefix"]
    end

    def awslogs_options_for(name)
      container_definition = @container_definitions.find{|c|  c[:name] == name}
      return unless container_definition
      log_configuration = container_definition[:log_configuration]
      return unless  log_configuration && log_configuration[:log_driver] == 'awslogs'
      log_configuration[:options]
    end

    def awslog_client(region)
      @awslog_clients[region] ||= Aws::CloudWatchLogs::Client.new(region:region)
    end

    def get_log_events(container, next_token=nil)
      name = container.name
      options = awslogs_options_for(name)
      return unless options
      logclient = awslog_client(options["awslogs-region"])
      task_id = container.task_arn.split('/').last
      stream = "#{options["awslogs-stream-prefix"]}/#{name}/#{task_id}"
      response = logclient.get_log_events(
        log_group_name:  options["awslogs-group"],
        log_stream_name: stream,
        next_token: next_token,
      )
      response.events.map do |e|
        logger.info("[#{container.name}] [#{Time.at(e.timestamp/1000)}] #{e.message}")
      end
    rescue Aws::CloudWatchLogs::Errors::ResourceNotFoundException => e
      logger.warn("#{stream} does not exixs.")
    end

    def run(info)
      resp = client.run_task({
        cluster:         info[:cluster],
        task_definition: @task_definition_name,
        overrides: {
          container_overrides: info[:container_overrides] || []
        },
        count:       info[:count] || 1,
        started_by: "capistrano",
      })
      unless resp.failures.empty?
        resp.failures.each do |f|
          raise "#{f.arn}: #{f.reason}"
        end
      end

      wait_targets = Array(info[:wait_stop])
      failed = false
      unless wait_targets.empty?
        task_arns = resp.tasks.map { |t| t.task_arn }
        options = { cluster: info[:cluster], tasks: task_arns }
        run_waiter_options = Hash(info[:waiter_options]
        default_waiter_options = fetch(:run_task_waiter_options) || {}
        waiter_options = default_waiter_options.merge(run_waiter_options)

        begin
          wait_until(:tasks_running, options,waiter_options)
        rescue  Aws::Waiters::Errors::FailureStateError => e
        end

        begin
          wait_until(:tasks_stopped, options)
        rescue  Aws::Waiters::Errors::FailureStateError => e
          failed = e
        end

        resp = client.describe_tasks(options)

        resp.tasks.each do |t|
          t.containers.each do |c|
            if has_stream_prefix?(c.name)
              get_log_events(c)
            end
            next unless wait_targets.include?(c.name)

            unless c.exit_code && c.exit_code.zero?
              if c.reason
                raise "Conatiner (\"#{c.name}\" container in \"#{@task_definition_name}\" task) has errors: #{c.reason}"
              else
                raise "Conatiner (\"#{c.name}\" container in \"#{@task_definition_name}\" task) has errors: Exit: #{c.exit_code}"
              end
            end
          end
        end
      end

      if failed
        raise e
      end

      logger.info "run task [#{@task_definition_name} #{info.inspect}] [#{@region}] [#{Paint['OK', :green]}]"
    end
  end
end
