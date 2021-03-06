#
# Copyright (c) 2009-2013 RightScale Inc
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

module RightScale

  # Helper class used to initialize secure serializer for agents
  class SecureSerializerInitializer

    # Initialize serializer
    #
    # === Parameters
    # agent_type(String):: Agent type used to build filename of certificate and key
    # agent_id(String):: Serialized agent identity
    #
    # === Return
    # true:: Always return true
    def self.init(agent_type, agent_id)
      cert = Certificate.load(AgentConfig.certs_file("#{agent_type}.cert"))
      key = RsaKeyPair.load(AgentConfig.certs_file("#{agent_type}.key"))
      router_cert = Certificate.load(AgentConfig.certs_file("router.cert"))
      store = StaticCertificateStore.new(cert, key, router_cert, router_cert)
      SecureSerializer.init(Serializer.new, agent_id, store)
      true
    end

  end

end
