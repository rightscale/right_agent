#
# Copyright (c) 2009-2011 RightScale Inc
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
#

require File.expand_path(File.join(File.dirname(__FILE__), '..', 'spec_helper'))
require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'lib', 'right_agent', 'core_payload_types'))

module RightScale
  describe DevRepositories do
    before(:each) do
      @expected_repo1 = { "111" => DevRepository.new(:git, "bunk", nil, nil, nil, nil, nil, "111", [1,2,3]) }
      @expected_repo2 = { "222" => DevRepository.new(:git, "err", nil, nil, nil, nil, nil, "222", [4,5,6]) }
    end

    context 'empty?' do
      it 'should be empty by default' do
        DevRepositories.new.empty?.should be_true
      end

      it 'should not be empty when initialized with data' do
        DevRepositories.new(@expected_repo1).empty?.should be_false
      end

      it 'should should not be empty when a repo is added' do
        dev_repos = DevRepositories.new
        dev_repos.add_repo("111", {:repo_type=>:git, :url=>"bunk"}, [1,2,3])
        dev_repos.empty?.should be_false
      end
    end

    context 'add_repo' do
      it 'when initially empty, should add without error' do
        dev_repos = DevRepositories.new
        dev_repos.add_repo("111", {:repo_type=>:git, :url=>"bunk"}, [1,2,3])
        dev_repos.serialized_members.first.should == @expected_repo1
      end

      it 'when initialized with data, should add without error' do
        dev_repos = DevRepositories.new(@expected_repo1)
        dev_repos.add_repo("222", {:repo_type=>:git, :url=>"err"}, [4,5,6])
        dev_repos.serialized_members.first.should == @expected_repo1.merge(@expected_repo2)
      end
    end
  end
end
