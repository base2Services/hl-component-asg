CloudFormation do

  az_conditions_resources('SubnetCompute', maximum_availability_zones)

  safe_component_name = component_name.capitalize.gsub('_','').gsub('-','')

  EC2_SecurityGroup("SecurityGroup#{safe_component_name}") do
    GroupDescription FnSub("${EnvironmentName}-#{component_name}")
    VpcId Ref('VPCId')
  end
  
  security_groups.each do |name, sg|
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
  end if defined? security_groups

  Role('Role') do
    AssumeRolePolicyDocument service_role_assume_policy('ec2')
    Path '/'
    Policies(IAMPolicies.new.create_policies(iam_policies))
  end

  InstanceProfile('InstanceProfile') do
    Path '/'
    Roles [Ref('Role')]
  end

  LaunchConfiguration('LaunchConfig') do
    ImageId Ref('Ami')
    InstanceType Ref('InstanceType')
    AssociatePublicIpAddress public_address
    IamInstanceProfile Ref('InstanceProfile')
    KeyName Ref('KeyName')
    SecurityGroups [ Ref("SecurityGroup#{safe_component_name}") ]
    UserData FnBase64(FnSub(user_data))
  end

  AutoScalingGroup('AutoScaleGroup') do
    UpdatePolicy('AutoScalingRollingUpdate', {
      "MinInstancesInService" => asg_update_policy['min'],
      "MaxBatchSize"          => asg_update_policy['batch_size'],
      "SuspendProcesses"      => asg_update_policy['suspend']
    })
    LaunchConfigurationName Ref('LaunchConfig')
    HealthCheckGracePeriod health_check_grace_period
    MinSize Ref('MinSize')
    MaxSize Ref('MaxSize')
    VPCZoneIdentifier az_conditional_resources('SubnetCompute', maximum_availability_zones)
    addTag("Name", FnSub("${EnvironmentName}-#{component_name}-xx"), true)
    addTag("Environment",Ref('EnvironmentName'), true)
    addTag("EnvironmentType", Ref('EnvironmentType'), true)
  end

  Output("SecurityGroup#{safe_component_name}", Ref("SecurityGroup#{safe_component_name}"))
  Output("AutoScaleGroup#{safe_component_name}", Ref('AutoScaleGroup'))

end