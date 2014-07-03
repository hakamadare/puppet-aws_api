require 'rubygems'

module Puppet_X
  module Bobtfish
    class NoCredentialsError < Exception
    end
  end
end

class Puppet_X::Bobtfish::Ec2_api < Puppet::Provider
  HAVE_AWS_SDK = begin; require 'aws-sdk'; true; rescue Exception; false; end

  confine :true => HAVE_AWS_SDK

  desc "Helper for Providers which use the EC2 API"
  self.initvars

  def self.instances
    raise NotImplementedError
  end

  def self.prefetch(resources)
    catalog = resources.values.first.catalog
    creds = catalog.resources.find_all do |r|
      r.is_a?(Puppet::Type.type(:aws_credential))
    end
    credential_hashes = creds.collect {|x| extract_creds(x)}
    instances(credential_hashes).each do |provider|
      if resource = resources[provider.name] then
        resource.provider = provider
      end
    end
  end

  def self.name_or_id(item)
    return unless item
    item.tags.to_h['Name'] || item.id
  end
  def name_or_id(item)
    self.class.name_or_id(item)
  end

  def wait_until_state(item, state)
    sleep 1 until item.state == state
  end

  def tag_with_name(item, name)
    item.add_tag 'Name', :value => name
  end

  def get_creds
    @creds ||= begin
      if resource
        account = resource[:account]
        cred = resource.catalog.resources.find_all do |r|
          r.is_a?(Puppet::Type.type(:aws_credential)) && r.name == account
        end.first
      end
      if cred == nil
        warn "Account supplied did not match any in the catalog, falling back to defaults"
        self.class.default_creds
      else
        {:access_key_id => cred[:access_key], :secret_access_key => cred[:secret_key]}
      end
    end
  end

  def self.extract_creds(cred_resource)
    {
      :name => cred_resource[:name],
      :access_key_id => cred_resource[:access_key], 
      :secret_access_key => cred_resource[:secret_key]
    }
  end

  def self.default_creds
    creds = {
      :access_key_id => (ENV['AWS_ACCESS_KEY_ID']||ENV['AWS_ACCESS_KEY']), 
      :secret_access_key => (ENV['AWS_SECRET_ACCESS_KEY']||ENV['AWS_SECRET_KEY'])
    }
    unless creds.fetch(:access_key_id) {nil} and creds.fetch(:secret_access_key) {nil}
      raise Puppet_X::Bobtfish::NoCredentialsError, "No suitable aws credentials were found"
    end
    creds
  end

  def self.amazon_thing(which, creds=self.default_creds)
    which.new(creds)
  end

  def self.iam(creds=default_creds)
    amazon_thing(AWS::IAM, creds)
  end
  def iam
    self.class.iam(get_creds)
  end

  def self.ec2(creds=default_creds)
    amazon_thing(AWS::EC2, creds)
  end
  def ec2
    self.class.ec2(get_creds)
  end

  def self.regions(keys)
    @@regions ||= begin
      if HAVE_AWS_SDK
        ec2(keys).regions.collect { |r| r.name }
      else
        []
      end
    end
  end

  def regions
    self.class.regions(get_creds)
  end

  def tags=(newtags)
    newtags.each { |k,v| @property_hash[:aws_item].add_tag(k, :value => v) }
    @property_hash[:tags] = newtags
  end

  def self.find_dhopts_item_by_name(name, keys)
    @@dhoptions ||= begin
      regions(keys).collect do |region_name|
        ec2(keys).regions[region_name].dhcp_options.to_a
      end.flatten
    end
    @@dhoptions.find do |dopt|
      dopt_name = dopt.tags.to_h['Name'] || dopt.id
      dopt_name == name || dopt.id == name
    end
  end

  def find_dhopts_item_by_name(name)
    self.class.find_dhopts_item_by_name(name, get_creds)
  end

  def find_vpc_item_by_name(name)
    @@vpcs ||= begin
      regions.collect do |region_name|
        ec2.regions[region_name].vpcs.to_a
      end.flatten
    end
    @@vpcs.find do |vpc|
      vpc_name = vpc.tags.to_h['Name'] || vpc.vpc_id
      vpc_name == name
    end
  end

  def find_region_name_for_vpc_name(name)
    self.class.find_region_name_for_vpc_name(name, get_creds)
  end
  def self.find_region_name_for_vpc_name(name, keys)
    regions(keys).find do |region_name|
      ec2(keys).regions[region_name].vpcs.find do |vpc|
        vpc_name = vpc.tags.to_h['Name'] || vpc.vpc_id
        vpc_name == name
      end
    end
  end

  def flush
  end

  def exists?
    @property_hash[:ensure] == :present
  end

  def vpc=(vpc_name)
    vpc = find_vpc_item_by_name(vpc_name)
    if vpc.nil?
      fail("Cannot find vpc #{vpc_name}")
    end
    @property_hash[:aws_item].attach(vpc)
    @property_hash[:vpc] = vpc_name
  end
end
