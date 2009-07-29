#
# Copyright (c) 2009 RightScale Inc
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

class Chef 
  class Provider
    class DnsMadeEasy < Chef::Provider 
            
      def load_current_resource
          true
      end

      # setup the register action.  
      def action_register
        Chef::Log.info "Updating DNS for #{@new_resource.name} to point to #{@new_resource.ip_address}"
        query="username=#{@new_resource.user}&password=#{@new_resource.passwd}&id=#{@new_resource.name}&ip=#{@new_resource.ip_address}"
        Chef::Log.debug "QUERY: #{query}"
        result =  post_change(query)
        if( result =~ /success/ || result =~ /error-record-ip-same/   ) then
          Chef::Log.info "DNSID #{@new_resource.name} set to this instance IP: #{@new_resource.ip_address}"
        else
          raise Chef::Exceptions::Dns, "#{self.class.name}: Error setting #{@new_resource.name} to instance IP: #{@new_resource.ip_address}: Result: #{result}"
        end
      end
      
      # make the HTTPS request
      def post_change(query)
        `curl -S -s --retry 7 -k -o - -f 'https://www.dnsmadeeasy.com/servlet/updateip?#{query}'`
      end
      
    end
  end
end

class Chef
  class Platform
    @platforms ||= {}
  end
end 
Chef::Platform.platforms[:default].merge! :dns => Chef::Provider::DnsMadeEasy