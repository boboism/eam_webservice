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
                  bill_body.Entity do |entity|
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
        else
          interface.Entry do |entry|
            self.class.column_names.sort.each do |col|
              unless options[:except] && Array(options[:except]).include?(col.to_sym)
                entry.tag! col.to_s.camelize, self[col.to_sym]
              end
            end
          end
        end
      end
      xml.target!.to_s
    end
  end
end

class AdjDocF30 < ActiveRecord::Base
  self.table_name = "vw_erp_f30"
  self.primary_key = "id"
end


client = Savon.client(:wsdl => "http://172.18.81.20/BOI/Service.asmx?WSDL")
ws_attrs = {
  :interface => {:sender => "EAM", :receiver => "ERP", :billtype => "F30"},
  :func_name => "FixedAssetAdjustInfo",
  :handshake => "654321"
}
receivable_docs = []
unreceivable_docs = []
AdjDocF30.all.each do |doc|
  token = UUIDTools::UUID.random_create.to_s.gsub("-","").upcase
  parameters = doc.to_erp_xml(ws_attrs.merge({:except => [:id]}))
  resp = client.call(:boi_invoke, :message => {
    :from       => "#{ws_attrs[:interface][:sender]}#{ws_attrs[:handshake]}", 
    :to         => ws_attrs[:interface][:receiver], 
    :token      => token,
    :func_name  => "#{ws_attrs[:func_name]}_#{ws_attrs[:interface][:billtype]}", 
    :parameters => "#{parameters.to_s}" })
  #p parameters 
  if resp.body[:boi_invoke_response][:boi_invoke_result]
    receivable_docs << {doc.id => "TOKEN=#{token}"}
    doc.erp_synchronized = 1
    doc.save
  else
    unreceivable_docs << {doc.id => "TOKEN=#{token} #{resp.body[:boi_invoke_response][:result]}"}
  end
end
unreceivable_docs.each do |doc|
  doc = doc.flatten
  p "[WARN] #{doc.first} => #{doc.last}"
end
