module Matestack::Ui::Core::Component
  class Base < Trailblazer::Cell
    include Matestack::Ui::Core::Cell
    include Matestack::Ui::Core::HasViewContext

    # probably eed to remove for other tests to be green again
    include Matestack::Ui::Core::DSL

    view_paths << "#{Matestack::Ui::Core::Engine.root}/app/concepts"
    view_paths << "#{::Rails.root}/app/matestack"

    extend ViewName::Flat

    attr_reader :children, :yield_components_to

    # TODO: Seems the `context` method is defined in Cells, would be
    # easy to move up - question really is how much of cells we're still using?
    def initialize(model = nil, options = {})
      # @model also exists with the same content? Is there any reason we wouldn't
      # wanna use it instead of @argument? There's even a `model` accessor for it
      # TODO
      @argument = model
      @options = options

      # TODO works around a semantic where if just a hash is passed apparently
      # those are the options
      @options = model.dup if @options.empty? && model.is_a?(Hash)

      super(model, @options)
      # DSL-relevant
      @children = []
      @current_parent_context = self
      # remember where we need to insert components on yield_components_for usage
      @yield_components_to = nil

      # TODO: everything beyond this point is probably not needed for the
      # Page subclass

      # TODO: potentially only used in form like components
      # Suggestion: Introduce a new super class to remove this complexity
      # from the base class.
      @included_config = @options[:included_config]

      # TODO seemingly never accessed? (at least by us)
      # but probably good to expose to have access to current_user & friends
      # #context is defined in `Cell::ViewModel`
      # and it just grabs @options[:context]
      @controller_context = context&.fetch(:controller_context, nil)

      # TODO: technically only relevant for Dynamic, however it relies on
      # @options being set but must be set before `setup` is called.
      # As both happen in this controller it isn't possible to squeeze
      # it inbetween the super calls in the Dynamic super class.
      #
      # This is the configuration for the VueJS component
      @component_config = @options.except(:context, :children, :url_params, :included_config)

      # TODO: no idea why this is called `url_params` it contains
      # much more than this e.g. almost all params so maybe rename it?
      @url_params = context&.[](:params)&.except(:action, :controller, :component_key)

      # TODO: do we realy have to call this every time on initialize or should
      # it maybe be called more dynamically like its dynamic_tag_attributes
      # equivalent in Dynamic?
      set_tag_attributes
      setup
      validate_options
    end

    # TODO: modifies/recreates view lookup paths on every invocation?!
    # At least memoize it I guess...
    # better even maybe/probably give a component an (automatic) way to know
    # exactly where its template is probably based on its own file location.
    # Then no lookup/search has to happen.
    def self.prefixes
      _prefixes = super
      modified_prefixes = _prefixes.map do |prefix|
        prefix_parts = prefix.split("/")

        if prefix_parts.last.include?(self.name.split("::")[-1].downcase)
          prefix_parts[0..-2].join("/")
        else
          prefix
        end

      end

      return modified_prefixes + _prefixes
    end

    def self.views_dir
      return ""
    end

    # Special validation logic
    def validate_options
      if defined? self.class::REQUIRED_KEYS
        self.class::REQUIRED_KEYS.each do |key|
          raise "required key '#{key}' is missing" if options[key].nil?
        end
      end
      custom_options_validation
    end

    def custom_options_validation
      true
    end

    # custom component setup that doesn't seem to be documented
    # but lots of components use it
    def setup
      true
    end

    # Setup meant to be overridden to setup data from DB or what not
    # why not just call these functions at the beginning of whatever
    # we'll call the method like:
    #
    # def respone
    #   result = i_call_stuff
    #   plain result
    # end
    #
    # Seems like it might be more complicated? Not sure probably missing something.
    def prepare
      true
    end

    ## ------------------ Rendering ----------------
    # Invoked by Cell::ViewModel from Rendering#call
    #
    def show
      raise "subclass responsibility"
    end

    def to_html
      show
    end

    def render_content
      # When/if we implement response then our display purely relies on that
      # of our children
      # TODO: this might be another sub class or module for the difference
      # Like Native Component vs. composed component? Unsure. Might also not be worth it.
      if respond_to? :response
        render :children
      else
        # We got a template render it around our children
        render do
          render :children
        end
      end
    end

    def component_id
      options[:id] ||= nil
    end

    def js_action name, arguments
      argumentString = arguments.join('", "')
      argumentString = '"' + argumentString + '"'
      [name, '(', argumentString, ')'].join("")
    end

    def navigate_to path
      js_action("navigateTo", [path])
    end

    def get_children
      return options[:children]
    end

    ## ---------------------- DSL ------------------------------
    # Add a new child when building the component tree.
    #
    # Invoked in 2 ways
    # * directly ass add_child class, args, block
    # * as defined by the DSL methods in `Matestack::Ui::Core::Component::Registry`
    #   which does the same but allows the nicer DSL methods on top of it
    #
    # add_child only builds up the whole ruby component structure. Rendering is done
    # in a later step by calling `#show` on the component where you want to start
    # rendering.
    def add_child(child_class, *args, &block)
      args_with_context = add_context_to_options(args)

      child = child_class.new(*args_with_context)
      @current_parent_context.children << child

      child.prepare
      child.response if child.respond_to?(:response)

      execute_child_block(child, block) if block

      child
    end

    # compatibility layer to old-school (not needed anymore)
    def components(&block)
      instance_eval &block
    end

    # TODO: partial is weird, I highly recommend removing it
    # it exists in basically 2 forms, one that is basically `send`
    # the other just executes the block it's given.
    # Same thing can now be achieved through simple method calls
    def partial(*args)
      if block_given?
        yield
      else
        send(*args)
      end
    end

    # slot allows generating content in one component and passing it to another
    #
    # It's a 2 purpose method (might be redone):
    # * with a block creates the children to be inserted
    # * without a block it inserts the children at the current point
    #
    #
    def slot(slot_content = [], &block)
      if block_given?
        create_slot_children_to_be_inserted(block)
      else
        # at this point the children are completely built, we just need
        # to insert them into the tree at the right spot (which is marked
        # by where we are currently called hence @current_parent_context)
        @current_parent_context.children.concat(slot_content)
      end
    end

    # TODO the implementation is simple, but reasoning about is quite
    # complex imo. The main reason is that `yield_components` has no
    # access to the block. Of course that could be solved by making
    # it an instance variable. Might be nicer if we could do
    # `def response(&block)`
    # Also:
    # * right now only works with one yield_components, would break with
    #  two that might be nice to raise/warn about
    #
    # The biggest trick this pulls is in execte_child_block where the
    # parent context is shifted to whatever this points to, so that it's
    # inserted at the right point.
    def yield_components
      @yield_components_to = @current_parent_context
    end

    private

    # This should be simpler, all it does is try to figure out where the hash/option
    # argument goes and put context in it
    # Partially caused by the behavior that we have 2 initialize args and it's unclear
    # which one should be an options hash as both `plain "hello"` and `div id: "lala"`
    # should work currently
    def add_context_to_options(args)
      case args.size
      when 0 then [{context: context}]
      when 1 then
        arg = args.first
        if arg.is_a?(Hash)
          arg[:context] = context
          [arg]
        else
          [arg, {context: context}]
        end
      when 2 then
        args[1][:context] = context
        [args.first, args[1]]
      else
        raise "too many child arguments what are you doing?"
      end
    end

    def execute_child_block(child, block)
      previous_parent_context = @current_parent_context
      begin
        @current_parent_context = child.yield_components_to || child
        instance_eval(&block)
      ensure
        @current_parent_context = previous_parent_context
      end
    end

    def create_slot_children_to_be_inserted(block)
      # Basically works through:
      # 1. create a fake parent (execution_parent_proxy)
      # 2. set it as the current parrent
      # 3. evaluate the block in the context in which it was defined
      #    to have access to methods/instance variables
      # 4. make sure parent context is the previous one again
      # 5. return the children we added to our "fake parent" so
      #    that they can be inserted wherever again
      execution_parent_proxy = Base.new()
      previous_parent_context = @current_parent_context
      @current_parent_context = execution_parent_proxy

      begin
        instance_eval(&block)
      ensure
        @current_parent_context = previous_parent_context
      end

      execution_parent_proxy.children
    end

    ## ------------------------ Also Rendering ---------------------
    # common attribute handling for tags/components
    def set_tag_attributes
      default_attributes = {
        id: component_id,
        class: options[:class]
       }
       unless options[:attributes].nil?
         default_attributes.merge!(options[:attributes])
       end

       @tag_attributes = default_attributes
    end
  end
end
