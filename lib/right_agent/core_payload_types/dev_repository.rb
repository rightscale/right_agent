#--
# Copyright: Copyright (c) 2010-2011 RightScale, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# 'Software'), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#++

module RightScale
  # Sequence of cookbooks to be checked out on the instance.
  class DevRepository
    include Serializable

    # (Symbol) Type of repository: one of :git, :svn, :download or :local
    # * :git denotes a 'git' repository that should be retrieved via 'git clone'
    # * :svn denotes a 'svn' repository that should be retrieved via 'svn checkout'
    # * :download denotes a tar ball that should be retrieved via HTTP GET (HTTPS if uri starts with https://)
    # * :local denotes cookbook that is already local and doesn't need to be retrieved
    attr_accessor :repo_type
    # (String) URL to repository (e.g. git://github.com/opscode/chef-repo.git)
    attr_accessor :url
    # (String) git commit or svn branch that should be used to retrieve repository
    # Optional, use 'master' for git and 'trunk' for svn if tag is nil.
    # Not used for raw repositories.
    attr_accessor :tag
    # (Array) Path to cookbooks inside repostory
    # Optional (use location of repository as cookbook path if nil)
    attr_accessor :cookbooks_path
    # (String) Private SSH key used to retrieve git repositories
    # Optional, not used for svn and raw repositories.
    attr_accessor :ssh_key
    # (String) Username used to retrieve svn and raw repositories
    # Optional, not used for git repositories.
    attr_accessor :username
    # (String) Password used to retrieve svn and raw repositories
    # Optional, not used for git repositories.
    attr_accessor :password
    # (String) hash of the CookbookSequence that corresponds to the repo
    attr_accessor :repo_sha
    # (Array) List of cookbook <name, position> pairs
    attr_accessor :positions

    # Initialize fields from given arguments
    def initialize(*args)
      @repo_type              = args[0]
      @url                    = args[1] if args.size > 1
      @tag                    = args[2] if args.size > 2
      @cookbooks_path         = args[3] if args.size > 3
      @ssh_key                = args[4] if args.size > 4
      @username               = args[5] if args.size > 5
      @password               = args[6] if args.size > 6
      @repo_sha               = args[7] if args.size > 7
      @positions              = args[8] if args.size > 8
    end

    # Array of serialized fields given to constructor
    def serialized_members
      [ @repo_type, @url, @tag, @cookbooks_path, @ssh_key, @username, @password, @repo_sha, @positions ]
    end

    # Maps the given DevRepository to a has that can be consumed by the RightScraper gem
    #
    # === Returns
    # (Hash)::
    #   :repo_type (Symbol):: Type of repository: one of :git, :svn, :download or :local
    #     * :git denotes a 'git' repository that should be retrieved via 'git clone'
    #     * :svn denotes a 'svn' repository that should be retrieved via 'svn checkout'
    #     * :download denotes a tar ball that should be retrieved via HTTP GET (HTTPS if uri starts with https://)
    #     * :local denotes cookbook that is already local and doesn't need to be retrieved
    #   :url (String):: URL to repository (e.g. git://github.com/opscode/chef-repo.git)
    #   :tag (String):: git commit or svn branch that should be used to retrieve repository
    #                       Optional, use 'master' for git and 'trunk' for svn if tag is nil.
    #                       Not used for raw repositories.
    #   :cookbooks_path (Array):: Path to cookbooks inside repostory
    #                                             Optional (use location of repository as cookbook path if nil)
    #   :first_credential (String):: Either the Private SSH key used to retrieve git repositories, or the Username used to retrieve svn and raw repositories
    #   :second_credential (String):: Password used to retrieve svn and raw repositories
    def to_scraper_hash
      repo = {}
      repo[:repo_type]            = repo_type.to_sym unless repo_type.nil?
      repo[:url]                  = url
      repo[:tag]                  = tag
      repo[:resources_path]       = cookbooks_path
      if !ssh_key.nil?
        repo[:first_credential]   = ssh_key
      elsif !(username.nil? && password.nil?)
        repo[:first_credential]   = dev_repo.username
        repo[:second_credential]  = dev_repo.password
      end
      repo
    end
  end
end
