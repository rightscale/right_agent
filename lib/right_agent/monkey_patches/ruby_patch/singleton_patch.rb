#
# Copyright (c) 2011 RightScale Inc
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

require 'singleton'

module RightScale

  module Singleton

    module ClassMethods

      # Redirect missing class methods to singleton instance.
      def method_missing(meth, *args, &blk)
        self.instance.__send__(meth, *args, &blk)
      end

      # Since missing class methods are redirected, this class responds to
      # anything its singleton instance will respond to, in addition to all
      # of its own methods.
      def respond_to?(meth)
        super(meth) || self.instance.respond_to?(meth)
      end
    end

    # Upon inclusion, also include standard Singleton mixin
    def self.included(base)
      base.__send__(:include, ::Singleton)
      base.__send__(:extend, ClassMethods)
    end

  end

end
