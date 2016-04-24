require 'pathname'
require_relative './chopped_nginx_providers.rb'

module Chopped
  module Nginx
    # path helper for NGINX config paths
    class Helper
      attr_reader :node
      def initialize(node)
        @node = node
      end

      # where all the nginx config file lives
      def home
        Pathname.new(node.chopped.nginx.nginx_home)
      end

      # where configs that we include into the http {} context live
      def http_d
        home.join('http.conf.d')
      end

      # where configs that we include into the main context live
      def bare_d
        home.join('bare.conf.d')
      end

      # the core nginx conf file
      def conf
        home.join('nginx.conf')
      end

      # returns the name and path for base chopped_nginx_config_file resource
      def bare_resource(resource)
        inner_name = "bare_#{resource.name}"
        inner_path = bare_d.join("#{resource.name}.conf").to_s
        return inner_name, inner_path
      end

      def http_resource(resource)
        inner_name = "http_#{resource.name}"
        inner_path = http_d.join("#{resource.name}.conf").to_s
        return inner_name, inner_path
      end
    end

    INDENT = '  '
    NEWLINE = "\n"

    def self.indent(ast, level = 0)
      final_lines = []
      ast.each do |item|
        if item.is_a? Enumerable
          final_lines.concat(indent(item, level + 1))
        else
          final_lines << INDENT * level + item.to_s
        end
      end
      final_lines
    end

    # meat and potatoes.
    # generate an nginx config file from a ruby data structure made out of
    # the classes in Chopped::Nginx::AST
    def self.generate(tree)
      array = tree._render
      lines = indent(array, 0)
      lines.join(NEWLINE) + NEWLINE
    end

    # A domain-specific language function that renders a complete config file
    # string, including a warning that the config was generated by Chef.
    def self.config(&block)
      cfg = AST::Config.new(&block)
      cfg.children.unshift(AST::Comment.new('Beware: manual edits will be overwritten by future Chef runs.'))
      cfg.children.unshift(AST::Comment.new('This config was generated by Chef.'))
      generate(cfg)
    end

    module AST
      module DSL
        # Load a list of nginx directives that this module should support.
        # Directive files are newline-seperated text files where each directive
        # is the first word of a line. You can generate this list by pasting the
        # page text of directives from http://nginx.org/en/docs/dirindex.html
        # This library includes that list - and provides this method to allow
        # support for NGINX extensions.
        def self.load_support(text_file_path)
          lines = Pathname.new(text_file_path).read.split("\n")
          lines.each do |line|
            directive = line.split(/\s+/).first
            support_directive(directive)
          end
        end

        # add support for a single directive.
        # @param [String, Symbol] meth the directive name
        # @see http://nginx.org/en/docs/dirindex.html
        #
        # this functionality was originally implemented in method_missing, and
        # allowed any word as a directive, but that prevented intelligent_eval
        # from accessing the parent scope of a block.
        def self.support_directive(meth)
          meth = meth.to_sym
          define_method(meth) do |*args, &block|
            if !block.nil?
              total = [meth].concat(args)
              self._block(*total, &block)
            else
              self._prop(meth, *args)
            end
          end
        end

        # @param [Proc] block a dsl block
        # allows both styles of dsl:
        #
        # foo do |f|
        #   f.a :hello
        #   f.b :world
        # end
        #
        # and
        #
        # foo do
        #   a :hello
        #   b :world
        # end
        #
        # also preserve the scope of block.
        def intelligent_eval(block)
          if block.arity > 0
            block.call(self)
          else
            scope = ::Chopped::CombinedScope.new(self)
            scope.evaluate(block)
          end
        end

        # methods are prefixed with underscores to prevent conflicting with
        # actual NGINX directive names.
        def _push(item)
          children.push(item)
        end

        def _render
          # this flatten(1) is needed to keep block titles from over-indenting
          children.map { |c| c._render }.flatten(1)
        end

        # should s/block/context/g - a block is an NGINX context.
        # it looks like this:
        # block title {
        #   block child
        #   block child 2
        #   ...
        # }
        def _block(*title, &dsl_block)
          blk = Block.new(title, [], &dsl_block)
          _push(blk)
        end

        # aka directive
        def _prop(title, *values)
          _push(Directive.new(title, values))
        end

        def comment(text)
          _push(Comment.new(text))
        end

        def to_s
          Chopped::Nginx.generate(self)
        end
      end # end DSL

      class Config
        include DSL
        attr_reader :children

        def initialize(&block)
          @children = []

          if block_given?
            intelligent_eval(block)
          end
        end
      end # end Config

      class Block < Struct.new('Block', :title, :children)
        include DSL

        def initialize(title, children = [], &block)
          super(title, children)
          if block_given?
            intelligent_eval(block)
          end
        end

        def _render
          title_s = (title + ['{']).join(' ')
          children_array = super
          close_s = '}'

          [title_s, children_array, close_s]
        end
      end # end Block

      Directive = Struct.new('Directive', :title, :values) do
        def _render
          ([title] + values).join(' ') + ';'
        end
      end # end Directive

      Comment = Struct.new('Comment', :text) do
        def _render
          '# ' + text
        end
      end # end Comment
    end # end module AST
  end # end module NGINX
end # end module Chopped

directives_path = Pathname.new(__FILE__).dirname.join('nginx_directives.txt').to_s
Chopped::Nginx::AST::DSL.load_support(directives_path)

# TODO: real unit tests
# har har har
def test
  b = Chopped::Nginx.config do
    user 'foo bar'
    worker_processes 5

    server :dog do
      root :jackie
      satisfy 55
    end

    server :cat do
      root :rat
      satisfy :face
      queue '"what"'
    end
  end
end
