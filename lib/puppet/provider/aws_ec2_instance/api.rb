require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', '..', 'puppet_x', 'bobtfish', 'ec2_api.rb'))

Puppet::Type.type(:aws_ec2_instance).provide(:api, :parent => Puppet_X::Bobtfish::Ec2_api) do
  mk_resource_methods

  def self.instances_for_region(region)
    ec2.regions[region].instances
  end
  def instances_for_region(region)
    self.class.instances_for_region region
  end
  def self.new_from_aws(region_name, item)
    tags = item.tags.to_h
    name = tags.delete('Name') || item.id

    profile = nil
    if item.iam_instance_profile_id
      profile = find_instance_profile_by_id(item.iam_instance_profile_id)[:instance_profile_name]
    end

    subnet = nil
    if item.subnet
      subnet = item.subnet.tags['Name']
    end

    key_pair = nil
    if item.key_pair
      key_pair = item.key_pair.name
    end

    block_devices = item.block_device_mappings.to_h.map do |mount, dev|
      {
        'device_name' => mount,
        'ebs' => {
          'volume_size' => dev.volume.size.to_s,
          'delete_on_termination' => dev.delete_on_termination,
          'volume_type' => if dev.volume.iops then 'io1' else 'standard' end # i think this is right?
        }
      }
    end
    new(
      :aws_item         => item,
      :name             => name,
      :id               => item.id,
      :ensure           => if item.status == :running then :present else item.status end,
      :region           => region_name,
      :image_id         => item.image_id,
      :instance_type    => item.instance_type,
      :iam_role         => profile,
      :subnet           => subnet,
      :key_name         => key_pair,
      :tags             => tags,
      :elastic_ip       => !!item.elastic_ip,
      :block_device_mappings => block_devices,
      :security_groups  => item.security_groups.collect(&:name),
      :public_ip_address=> item.public_ip_address
    )
  end

  def self.instances
    regions.collect do |region_name|
      # Swapping out the default region like seems to be necessary (sometimes - it's not
      # very deterministic), the subnet lookup can get confused otherwise.
      prev_region_conf = AWS.config.region
      AWS.config(:region => region_name)
      results = instances_for_region(region_name).find_all(&:exists?).collect { |item|
        new_from_aws(region_name, item)
      }
      AWS.config(:region => prev_region_conf)
      results
    end.flatten
  end

  read_only(:image_id, :instance_type, :iam_role, :region, :subnet, :subnet, :key_name,
    :elastic_ip, :block_device_mappings, :security_groups)

  def create
    if aws_item
      case aws_item.status
      when :pending, :running
        # just wait
        wait_until_status(aws_item, :running)
        return
      when :shutting_down, :stopped, :stopping
        # Finish what you were doing
        aws_item.stop
        wait_until_status(aws_item, :stopped)
        # Now start
        aws_item.start
        wait_until_status(aws_item, :running)
        return
      end
    end
    profile = iam.client.get_instance_profile(
      :instance_profile_name => resource[:iam_role]
    )
    region = ec2.regions[resource[:region]]
    subnet = region.subnets.with_tag('Name', resource[:subnet]).first

    block_devices = resource['block_device_mappings'].each_with_index do |dev, i|
      # Fun fact: puppet doesn't have an int type
      if dev['ebs'] and dev['ebs']['volume_size']
        dev['ebs']['volume_size'] = dev['ebs']['volume_size'].to_i
      end
      # Just auto-name, we can't actually get this name back and it pretty much
      # has to follow this pattern anyway
      dev['virtual_name'] = "ephemeral#{i}"
    end

    instance = region.instances.create(
      :iam_instance_profile => profile[:instance_profile][:arn],
      :image_id             => resource[:image_id],
      :instance_type        => resource[:instance_type],
      :subnet               => subnet.id,
      :key_name             => resource[:key_name],
      :associate_public_ip_address => resource[:associate_public_ip_address],
      :block_device_mappings => block_devices,
      :security_groups => resource[:security_groups].map do |group_name|
        subnet.vpc.security_groups.with_tag('Name', group_name).first
      end
    )
    # Tag name immediately so we don't just keep building instances if this fails
    tag_with_name instance, resource[:name]
    tags = resource[:tags] || {}
    tags.each { |k,v| instance.add_tag(k, :value => v) }

    if resource[:elastic_ip]
      elastic_ip = region.elastic_ips.create(
        :vpc => true,
      )
    end
    wait_until_status instance, :running

    if resource[:elastic_ip]
      instance.associate_elastic_ip(elastic_ip)
    end


    instance.block_devices.each do |dev|
      if dev[:ebs] and dev[:ebs][:volume_id]
        name = dev[:device_name].sub(/^\/dev\//, '')
        region.volumes[dev[:ebs][:volume_id]].add_tag('Name', :value => "#{resource[:name]}-#{name}")
      end
    end

    instance
  end
  def destroy
    region = ec2.regions[@property_hash[:region]]
    instance = @property_hash[:aws_item]
    sda1 = nil
    ip = instance.elastic_ip
    instance.block_devices.each do |dev|
      if dev[:ebs] and dev[:ebs][:volume_id] and dev[:device_name] == '/dev/sda1'
        sda1 = region.volumes[dev[:ebs][:volume_id]]
      end
    end
    instance.delete
    instance.tags['Name'] = @property_hash[:name] + "-terminated"
    wait_until_status instance, :terminated
    sda1.delete
    ip.delete
    @property_hash[:ensure] = :absent
  end
end

