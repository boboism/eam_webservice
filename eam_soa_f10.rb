require 'rubygems'
require 'tiny_tds'
require 'activerecord-sqlserver-adapter'
require 'savon'
require 'uuidtools'

ActiveRecord::Base.establish_connection(:adapter => "sqlserver", :host => "172.18.81.157", :database => "eam_dev", :username => "eam_prd", :password => "gamc2010@", :mode => "dblib", :encoding => "UTF-8")

module ActiveRecord
  class Base
    def to_erp_xml(options={})
      require 'builder' unless defined?(Builder)
      options = options.dup
      xml = ::Builder::XmlMarkup.new
      xml.instruct! :xml, :version => "1.0", :encoding => "UTF-8"
      interface_attributes = [:sender, :receiver, :billtype].inject({}) do |acc, im| 
        acc.merge({im.to_s.camelize => options[:interface][im]}) if options[:interface][im]
      end
      xml.Interface(interface_attributes) do |interface|
        if options[:include]
          interface.Bill do |bill|
            bill.BillHeader do |bill_header|
              self.class.column_names.sort.each do |col|
                unless options[:except] && Array(options[:except]).include?(col.to_sym)
                  bill_header.tag! col.to_s.camelize, self[col.to_sym]
                end
              end
            end
            bill.BillBody do |bill_body|
              Array(options[:include]).each do |attr|
                self.send(attr.to_sym).each do |association|
                  bill_body.Entry do |entity|
                    association.class.column_names.sort.each do |col| 
                      unless options[:except] && Array(options[:except]).include?(col.to_sym)
                        entity.tag! col.to_s.camelize, association[col.to_sym]
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
      xml.target!.to_s
    end
  end
end

class AssetF10 < ActiveRecord::Base
  self.table_name = "vw_asset_erp"
  self.primary_key = "id"

  has_many :allocations, :class_name => "AllocationF10", :foreign_key => "asset_id"
end

class AllocationF10 < ActiveRecord::Base
  self.table_name = "vw_asset_allocation_erp"
  self.primary_key = "id"

  belongs_to :asset, :class_name => "AssetF10"#, :foreign_key => "asset_id"
end

client = Savon.client(:wsdl => "http://172.18.81.20/BOI/Service.asmx?WSDL")
ws_attrs = {
  :interface => {:sender => "EAM", :receiver => "ERP", :billtype => "F10"},
  :func_name => "FixedAssetImport",
  :handshake => "654321"
}
receivable_assets = []
unreceivable_assets = []
AssetF10.all.each do |asset|
  token = UUIDTools::UUID.random_create.to_s.gsub("-","").upcase
  parameters = asset.to_erp_xml(ws_attrs.merge({:include => :allocations, :except => [:id, :asset_sync_status, :asset_id]}))
  resp = client.call(:boi_invoke, :message => {
    :from       => "#{ws_attrs[:interface][:sender]}#{ws_attrs[:handshake]}", 
    :to         => ws_attrs[:interface][:receiver], 
    :token      => token,
    :func_name  => "#{ws_attrs[:func_name]}_#{ws_attrs[:interface][:billtype]}", 
    :parameters => "#{parameters.to_s}" })
  p parameters 
  if resp.body[:boi_invoke_response][:boi_invoke_result]
    receivable_assets << {asset.asset_no => "TOKEN=#{token}"}
    # update records
    asset.asset_sync_status = 1
    asset.save
  else
    unreceivable_assets << {asset.asset_no => "TOKEN=#{token} #{resp.body[:boi_invoke_response][:result]}"}
  end
end
p unreceivable_assets.count
unreceivable_assets.each do |asset|
  asset = asset.flatten
  p "[WARN] #{asset.first} => #{asset.last}"
end
