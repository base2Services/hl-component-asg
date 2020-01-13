CloudFormation do

  maximum_availability_zones = external_parameters.fetch(:maximum_availability_zones, 5)
  az_conditions_resources('SubnetCompute', maximum_availability_zones)

  safe_component_name = external_parameters[:component_name].capitalize.gsub('_','').gsub('-','')

  sg_tags = []
  sg_tags << { Key: 'Environment', Value: Ref(:EnvironmentName)}
  sg_tags << { Key: 'EnvironmentType', Value: Ref(:EnvironmentType)}
  sg_tags << { Key: 'Name', Value: FnSub("${EnvironmentName}-#{external_parameters[:component_name]}")}

  extra_tags = external_parameters.fetch(:extra_tags, {})
  extra_tags.each { |key,value| sg_tags << { Key: "#{key}", Value: FnSub(value) } }

  Condition("SpotPriceSet", FnNot(FnEquals(Ref('SpotPrice'), '')))

  EC2_SecurityGroup("SecurityGroup#{safe_component_name}") do
    GroupDescription FnSub("${EnvironmentName}-#{external_parameters[:component_name]}")
    VpcId Ref('VPCId')
    Tags sg_tags
  end


  external_parameters[:security_groups].each do |name, sg|
    sg['ports'].each do |port|
      EC2_SecurityGroupIngress("#{name}SGRule#{port['from']}") do
        Description FnSub("Allows #{port['from']} from #{name}")
        IpProtocol 'tcp'
        FromPort port['from']
        ToPort port.key?('to') ? port['to'] : port['from']
        GroupId FnGetAtt("SecurityGroup#{safe_component_name}",'GroupId')
        SourceSecurityGroupId sg.key?('stack_param') ? Ref(sg['stack_param']) : Ref(name)
      end
    end if sg.key?('ports')
  end

  policies = []
  external_parameters[:iam_policies].each do |name,policy|
    policies << iam_policy_allow(name,policy['action'],policy['resource'] || '*')
  end

  Role('Role') do
    AssumeRolePolicyDocument service_role_assume_policy(['ec2','ssm'])
    Path '/'
    Policies(policies)
  end

  InstanceProfile('InstanceProfile') do
    Path '/'
    Roles [Ref('Role')]
  end

  volumes = []
  volume_size = external_parameters.fetch(:volume_size, nil)
  volumes << {
    DeviceName: '/dev/xvda',
    Ebs: {
      VolumeSize: volume_size
    }
  } unless volume_size.nil?

  LaunchConfiguration('LaunchConfig') do
    ImageId Ref('Ami')
    InstanceType Ref('InstanceType')
    BlockDeviceMappings volumes unless volume_size.nil?
    AssociatePublicIpAddress external_parameters[:public_address]
    IamInstanceProfile Ref('InstanceProfile')
    KeyName Ref('KeyName')
    SpotPrice FnIf('SpotPriceSet', Ref('SpotPrice'), Ref('AWS::NoValue'))
    SecurityGroups [ Ref("SecurityGroup#{safe_component_name}") ]
    UserData FnBase64(FnSub(external_parameters[:user_data]))
  end

  asg_tags = []
  asg_tags << { Key: 'Environment', Value: Ref(:EnvironmentName), PropagateAtLaunch: true }
  asg_tags << { Key: 'EnvironmentType', Value: Ref(:EnvironmentType), PropagateAtLaunch: true }
  asg_tags << { Key: 'Name', Value: FnJoin('-', [ Ref(:EnvironmentName), external_parameters[:component_name], 'xx' ]), PropagateAtLaunch: true }
  asg_tags << { Key: 'Role', Value: external_parameters[:component_name], PropagateAtLaunch: true }

  asg_extra_tags = external_parameters.fetch(:asg_extra_tags, {})
  extra_tags.each { |key,value| asg_tags.unshift({ Key: "#{key}", Value: FnSub(value), PropagateAtLaunch: true }) }
  asg_extra_tags.each { |key,value| asg_tags.unshift({ Key: "#{key}", Value: FnSub(value), PropagateAtLaunch: true }) }

  asg_loadbalancers = []
  loadbalancers = external_parameters.fetch(:loadbalancers, [])
  loadbalancers.each {|lb| asg_loadbalancers << Ref(lb)}

  asg_targetgroups = []
  targetgroups = external_parameters.fetch(:targetgroups, [])
  targetgroups.each {|lb| asg_targetgroups << Ref(lb)}

  name = external_parameters.fetch(:name, nil)
  cool_down = external_parameters.fetch(:cool_down, nil)
  asg_update_policy = external_parameters[:asg_update_policy]
  AutoScalingGroup('AutoScaleGroup') do
    AutoScalingGroupName name unless name.nil?
    Cooldown cool_down unless cool_down.nil?
    UpdatePolicy('AutoScalingRollingUpdate', {
      "MinInstancesInService" => asg_update_policy['min'],
      "MaxBatchSize"          => asg_update_policy['batch_size'],
      "SuspendProcesses"      => asg_update_policy['suspend']
    })
    LaunchConfigurationName Ref('LaunchConfig')
    HealthCheckGracePeriod external_parameters[:health_check_grace_period]
    HealthCheckType Ref('HealthCheckType')
    MinSize Ref('MinSize')
    MaxSize Ref('MaxSize')
    # TODO: LifecycleHookSpecificationList []
    LoadBalancerNames asg_loadbalancers if asg_loadbalancers.any?
    TargetGroupARNs asg_targetgroups if asg_targetgroups.any?
    TerminationPolicies external_parameters[:termination_policies]
    VPCZoneIdentifier az_conditional_resources('SubnetCompute', maximum_availability_zones)
    Tags asg_tags.uniq { |h| h[:Key] }
  end

  ecs_autoscale = external_parameters.fetch(:ecs_autoscale, {})
  unless ecs_autoscale.empty?

    if ecs_autoscale.has_key?('memory_high')

      Resource("MemoryReservationAlarmHigh") {
        Condition 'IsScalingEnabled'
        Type 'AWS::CloudWatch::Alarm'
        Property('AlarmDescription', "Scale-up if MemoryReservation > #{ecs_autoscale['memory_high']}% for 2 minutes")
        Property('MetricName','MemoryReservation')
        Property('Namespace','AWS/ECS')
        Property('Statistic', 'Maximum')
        Property('Period', '60')
        Property('EvaluationPeriods', '2')
        Property('Threshold', ecs_autoscale['memory_high'])
        Property('AlarmActions', [ Ref('ScaleUpPolicy') ])
        Property('Dimensions', [
          {
            'Name' => 'ClusterName',
            'Value' => Ref('EcsCluster')
          }
        ])
        Property('ComparisonOperator', 'GreaterThanThreshold')
      }

      Resource("MemoryReservationAlarmLow") {
        Condition 'IsScalingEnabled'
        Type 'AWS::CloudWatch::Alarm'
        Property('AlarmDescription', "Scale-down if MemoryReservation < #{ecs_autoscale['memory_low']}%")
        Property('MetricName','MemoryReservation')
        Property('Namespace','AWS/ECS')
        Property('Statistic', 'Maximum')
        Property('Period', '60')
        Property('EvaluationPeriods', '2')
        Property('Threshold', ecs_autoscale['memory_low'])
        Property('AlarmActions', [ Ref('ScaleDownPolicy') ])
        Property('Dimensions', [
          {
            'Name' => 'ClusterName',
            'Value' => Ref('EcsCluster')
          }
        ])
        Property('ComparisonOperator', 'LessThanThreshold')
      }

    end

    if ecs_autoscale.has_key?('cpu_high')

      Resource("CPUReservationAlarmHigh") {
        Condition 'IsScalingEnabled'
        Type 'AWS::CloudWatch::Alarm'
        Property('AlarmDescription', "Scale-up if CPUReservation > #{ecs_autoscale['cpu_high']}%")
        Property('MetricName','CPUReservation')
        Property('Namespace','AWS/ECS')
        Property('Statistic', 'Maximum')
        Property('Period', '60')
        Property('EvaluationPeriods', '2')
        Property('Threshold', ecs_autoscale['cpu_high'])
        Property('AlarmActions', [ Ref('ScaleUpPolicy') ])
        Property('Dimensions', [
          {
            'Name' => 'ClusterName',
            'Value' => Ref('EcsCluster')
          }
        ])
        Property('ComparisonOperator', 'GreaterThanThreshold')
      }

      Resource("CPUReservationAlarmLow") {
        Condition 'IsScalingEnabled'
        Type 'AWS::CloudWatch::Alarm'
        Property('AlarmDescription', "Scale-up if CPUReservation < #{ecs_autoscale['cpu_low']}%")
        Property('MetricName','CPUReservation')
        Property('Namespace','AWS/ECS')
        Property('Statistic', 'Maximum')
        Property('Period', '60')
        Property('EvaluationPeriods', '2')
        Property('Threshold', ecs_autoscale['cpu_low'])
        Property('AlarmActions', [ Ref('ScaleDownPolicy') ])
        Property('Dimensions', [
          {
            'Name' => 'ClusterName',
            'Value' => Ref('EcsCluster')
          }
        ])
        Property('ComparisonOperator', 'LessThanThreshold')
      }

    end

    Resource("ScaleUpPolicy") {
      Condition 'IsScalingEnabled'
      Type 'AWS::AutoScaling::ScalingPolicy'
      Property('AdjustmentType', 'ChangeInCapacity')
      Property('AutoScalingGroupName', Ref('AutoScaleGroup'))
      Property('Cooldown','300')
      Property('ScalingAdjustment', ecs_autoscale['scale_up_adjustment'])
    }

    Resource("ScaleDownPolicy") {
      Condition 'IsScalingEnabled'
      Type 'AWS::AutoScaling::ScalingPolicy'
      Property('AdjustmentType', 'ChangeInCapacity')
      Property('AutoScalingGroupName', Ref('AutoScaleGroup'))
      Property('Cooldown','300')
      Property('ScalingAdjustment', ecs_autoscale['scale_down_adjustment'])
    }
  end

  Output("SecurityGroup#{safe_component_name}", Ref("SecurityGroup#{safe_component_name}"))
  Output("AutoScaleGroup#{safe_component_name}", Ref('AutoScaleGroup'))

end
