# frozen_string_literal: true
require "spec_helper"

describe "Trace modes for schemas" do
  module TraceModesTest
    class ParentSchema < GraphQL::Schema
      module GlobalTrace
        def execute_query(query:)
          query.context[:global_trace] = true
          super
        end
      end

      module SpecialTrace
        def execute_query(query:)
          query.context[:special_trace] = true
          super
        end
      end

      module OptionsTrace
        def initialize(configured_option:, **_rest)
          @configured_option = configured_option
          super
        end

        def execute_query(query:)
          query.context[:configured_option] = @configured_option
          super
        end
      end

      class Query < GraphQL::Schema::Object
        field :greeting, String, fallback_value: "Howdy!"
      end

      query(Query)

      trace_with GlobalTrace
      trace_with SpecialTrace, mode: :special
      trace_with OptionsTrace, mode: :options, configured_option: :was_configured
    end

    class ChildSchema < ParentSchema
      module ChildSpecialTrace
        def execute_query(query:)
          query.context[:child_special_trace] = true
          super
        end
      end

      trace_with(ChildSpecialTrace, mode: [:special, :extra_special])
    end

    class GrandchildSchema < ChildSchema
      module GrandchildDefaultTrace
        def execute_query(query:)
          query.context[:grandchild_default] = true
          super
        end
      end

      trace_with GrandchildDefaultTrace
    end
  end

  it "traces are inherited from default modes" do
    res = TraceModesTest::ParentSchema.execute("{ greeting }")
    assert res.context[:global_trace]
    refute res.context[:grandchild_default]

    res = TraceModesTest::ChildSchema.execute("{ greeting }")
    assert res.context[:global_trace]
    refute res.context[:grandchild_default]

    res = TraceModesTest::GrandchildSchema.execute("{ greeting }")
    assert res.context[:global_trace]
    assert res.context[:grandchild_default]
  end

  it "inherits special modes" do
    res = TraceModesTest::ParentSchema.execute("{ greeting }", context: { trace_mode: :special })
    assert res.context[:global_trace]
    assert res.context[:special_trace]
    refute res.context[:child_special_trace]
    refute res.context[:grandchild_default]

    res = TraceModesTest::ChildSchema.execute("{ greeting }", context: { trace_mode: :special })
    assert res.context[:global_trace]
    assert res.context[:special_trace]
    assert res.context[:child_special_trace]
    refute res.context[:grandchild_default]

    # This doesn't inherit `:special` configs from ParentSchema:
    res = TraceModesTest::ChildSchema.execute("{ greeting }", context: { trace_mode: :extra_special })
    assert res.context[:global_trace]
    refute res.context[:special_trace]
    assert res.context[:child_special_trace]
    refute res.context[:grandchild_default]

    res = TraceModesTest::GrandchildSchema.execute("{ greeting }", context: { trace_mode: :special })
    assert res.context[:global_trace]
    assert res.context[:special_trace]
    assert res.context[:child_special_trace]
    assert res.context[:grandchild_default]
  end

  it "Only requires and passes arguments for the modes that require them" do
    res = TraceModesTest::ParentSchema.execute("{ greeting }", context: { trace_mode: :options })
    assert_equal :was_configured, res.context[:configured_option]
  end

  describe "inheriting from GraphQL::Schema" do
    it "gets CallLegacyTracers" do
      # Use a new base trace mode class to avoid polluting the base class
      # which already-initialized schemas have in their inheritance chain
      # (It causes `CallLegacyTracers` to end up in the chain twice otherwise)
      GraphQL::Schema.own_trace_modes[:default] = GraphQL::Schema.build_trace_mode(:default)

      child_class = Class.new(GraphQL::Schema)

      # Initialize the trace class, make sure no legacy tracers are present at this point:
      refute_includes child_class.trace_class_for(:default).ancestors, GraphQL::Tracing::CallLegacyTracers
      tracer_class = Class.new

      # add a legacy tracer
      GraphQL::Schema.tracer(tracer_class)
      # A newly created child class gets the right setup:
      new_child_class = Class.new(GraphQL::Schema)
      assert_includes new_child_class.trace_class_for(:default).ancestors, GraphQL::Tracing::CallLegacyTracers
      # But what about an already-created child class?
      assert_includes child_class.trace_class_for(:default).ancestors, GraphQL::Tracing::CallLegacyTracers

      # Reset GraphQL::Schema tracer state:
      GraphQL::Schema.send(:own_tracers).delete(tracer_class)
      GraphQL::Schema.own_trace_modes[:default] = GraphQL::Schema.build_trace_mode(:default)
      refute_includes GraphQL::Schema.new_trace.class.ancestors, GraphQL::Tracing::CallLegacyTracers
    end
  end

  describe "inheriting from a custom default trace class" do
    class CustomBaseTraceParentSchema < GraphQL::Schema
      class CustomTrace < GraphQL::Tracing::Trace
      end

      trace_class CustomTrace
    end

    class CustomBaseTraceSubclassSchema < CustomBaseTraceParentSchema
      trace_with Module.new, mode: :special_with_base_class
    end

    it "uses the default trace class for default mode" do
      assert_equal CustomBaseTraceParentSchema::CustomTrace, CustomBaseTraceParentSchema.trace_class_for(:default)
      assert_equal CustomBaseTraceParentSchema::CustomTrace, CustomBaseTraceSubclassSchema.trace_class_for(:default).superclass

      assert_instance_of CustomBaseTraceParentSchema::CustomTrace, CustomBaseTraceParentSchema.new_trace
      assert_kind_of CustomBaseTraceParentSchema::CustomTrace, CustomBaseTraceSubclassSchema.new_trace
    end

    it "uses the default trace class for special modes" do
      assert_includes CustomBaseTraceSubclassSchema.trace_class_for(:special_with_base_class).ancestors, CustomBaseTraceParentSchema::CustomTrace
      assert_kind_of CustomBaseTraceParentSchema::CustomTrace, CustomBaseTraceSubclassSchema.new_trace(mode: :special_with_base_class)
    end
  end

  describe "custom default trace mode" do
    class CustomDefaultSchema < TraceModesTest::ParentSchema
      class CustomDefaultTrace < GraphQL::Tracing::Trace
        def execute_query(query:)
          query.context[:custom_default_used] = true
          super
        end
      end

      trace_mode :custom_default, CustomDefaultTrace
      default_trace_mode :custom_default
    end

    class ChildCustomDefaultSchema < CustomDefaultSchema
    end

    it "inherits configuration" do
      assert_equal :default, TraceModesTest::ParentSchema.default_trace_mode
      assert_equal :custom_default, CustomDefaultSchema.default_trace_mode
      assert_equal :custom_default, ChildCustomDefaultSchema.default_trace_mode
    end

    it "uses the specified default when none is given" do
      res = CustomDefaultSchema.execute("{ greeting }")
      assert res.context[:custom_default_used]
      refute res.context[:global_trace]

      res2 = ChildCustomDefaultSchema.execute("{ greeting }")
      assert res2.context[:custom_default_used]
      refute res2.context[:global_trace]
    end
  end

  describe "custom mode options and default options" do
    class ModeOptionsSchema < GraphQL::Schema
      module SomePlugin
        def self.use(schema)
          schema.trace_with(Trace, arg1: 1)
        end

        module Trace
          def initialize(arg1:, **kwargs)
            super(**kwargs)
          end
        end
      end
      module BaseTracer
        def initialize(arg3:, **kwargs)
          super(**kwargs)
        end
      end

      module ExtraTracer
        def initialize(arg2:, **kwargs)
          super(**kwargs)
        end
      end

      use SomePlugin
      trace_with(ExtraTracer, mode: :extra, arg2: true)
      trace_with(BaseTracer, arg3: true)
    end

    it "merges default options into custom mode options" do
      assert_equal [:arg1, :arg3], ModeOptionsSchema.trace_options_for(:default).keys.sort
      assert_equal [:arg1, :arg2, :arg3], ModeOptionsSchema.trace_options_for(:extra).keys.sort

      assert ModeOptionsSchema.new_trace(mode: :default)
      assert ModeOptionsSchema.new_trace(mode: :extra)
    end
  end
end
