require "llvm"
require "../syntax/parser"
require "../syntax/visitor"
require "../semantic"
require "../program"
require "./llvm_builder_helper"

LLVM.init_x86

module Crystal
  MAIN_NAME          = "__crystal_main"
  RAISE_NAME         = "__crystal_raise"
  MALLOC_NAME        = "__crystal_malloc"
  REALLOC_NAME       = "__crystal_realloc"
  PERSONALITY_NAME   = "__crystal_personality"
  GET_EXCEPTION_NAME = "__crystal_get_exception"

  DataLayout32 = "e-p:32:32:32-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:32:64-f32:32:32-f64:32:64-v64:64:64-v128:128:128-a0:0:64-f80:32:32-n8:16:32"
  DataLayout64 = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v64:64:64-v128:128:128-a0:0:64-s0:64:64-f80:128:128-n8:16:32:64"

  class Program
    def run(code, filename = nil)
      parser = Parser.new(code)
      parser.filename = filename
      node = parser.parse
      node = normalize node
      node = semantic node
      evaluate node
    end

    def evaluate(node)
      llvm_mod = codegen(node, single_module: true)[""]
      main = llvm_mod.functions[MAIN_NAME]

      main_return_type = main.return_type

      # It seems the JIT doesn't like it if we return an empty type (struct {})
      main_return_type = LLVM::Void if node.type.nil_type?

      wrapper = llvm_mod.functions.add("__evaluate_wrapper", [] of LLVM::Type, main_return_type) do |func|
        func.basic_blocks.append "entry" do |builder|
          argc = LLVM.int(LLVM::Int32, 0)
          argv = LLVM::VoidPointer.pointer.null
          ret = builder.call(main, [argc, argv])
          (node.type.void? || node.type.nil_type?) ? builder.ret : builder.ret(ret)
        end
      end

      llvm_mod.verify

      engine = LLVM::JITCompiler.new(llvm_mod)
      engine.run_function wrapper, [] of LLVM::GenericValue
    end

    def codegen(node, single_module = false, debug = false, llvm_mod = LLVM::Module.new("main_module"), expose_crystal_main = true)
      visitor = CodeGenVisitor.new self, node, single_module: single_module, debug: debug, llvm_mod: llvm_mod, expose_crystal_main: expose_crystal_main
      node.accept visitor
      visitor.finish

      visitor.modules
    end

    def llvm_typer
      @llvm_typer ||= LLVMTyper.new(self)
    end

    def size_of(type)
      size = llvm_typer.size_of(llvm_typer.llvm_type(type))
      size = 1 if size == 0
      size
    end

    def instance_size_of(type)
      llvm_typer.size_of(llvm_typer.llvm_struct_type(type))
    end
  end

  class CodeGenVisitor < Visitor
    SYMBOL_TABLE_NAME = ":symbol_table"

    include LLVMBuilderHelper

    getter llvm_mod : LLVM::Module
    getter builder : CrystalLLVMBuilder
    getter main : LLVM::Function
    getter modules : Hash(String, LLVM::Module)
    getter context : Context
    getter llvm_typer : LLVMTyper
    getter alloca_block : LLVM::BasicBlock
    getter entry_block : LLVM::BasicBlock
    property last : LLVM::Value

    class LLVMVar
      getter pointer : LLVM::Value
      getter type : Type

      # Normally a variable is associated with an alloca.
      # So for example, if you have a "x = Reference.new" you will have
      # an "Reference**" llvm value and you need to load that value
      # to access it.
      # However, the "self" argument is not copied to a local variable:
      # it's accessed from the arguments list, and it a "Reference*"
      # llvm value, so in a way it's "already loaded".
      # This field is true if that's the case.
      getter already_loaded : Bool

      def initialize(@pointer, @type, @already_loaded = false)
      end
    end

    alias LLVMVars = Hash(String, LLVMVar)

    record Handler, node : ExceptionHandler, context : Context
    record StringKey, mod : LLVM::Module, string : String

    @abi : LLVM::ABI
    @main_ret_type : Type
    @argc : LLVM::Value
    @argv : LLVM::Value
    @empty_md_list : LLVM::Value
    @rescue_block : LLVM::BasicBlock?
    @malloc_fun : LLVM::Function?
    @sret_value : LLVM::Value?
    @cant_pass_closure_to_c_exception_call : Call?
    @realloc_fun : LLVM::Function?

    def initialize(@program : Program, @node : ASTNode, single_module = false, debug = false, @llvm_mod = LLVM::Module.new("main_module"), expose_crystal_main = true)
      @main_mod = @llvm_mod
      @single_module = !!single_module
      @debug = !!debug
      @abi = @program.target_machine.abi
      @llvm_typer = @program.llvm_typer
      @llvm_id = LLVMId.new(@program)
      @main_ret_type = node.type
      ret_type = @llvm_typer.llvm_return_type(node.type)
      @main = @llvm_mod.functions.add(MAIN_NAME, [LLVM::Int32, LLVM::VoidPointer.pointer], ret_type)
      @main.linkage = LLVM::Linkage::Internal unless expose_crystal_main

      emit_main_def_debug_metadata(@main, "??") if @debug

      @context = Context.new @main, @program
      @context.return_type = @main_ret_type

      @argc = @main.params[0]
      @argc.name = "argc"

      @argv = @main.params[1]
      @argv.name = "argv"

      builder = LLVM::Builder.new
      @builder = wrap_builder builder

      @dbg_kind = LibLLVM.get_md_kind_id("dbg", 3)

      @modules = {"" => @main_mod} of String => LLVM::Module
      @types_to_modules = {} of Type => LLVM::Module

      @alloca_block, @entry_block = new_entry_block_chain "alloca", "entry"

      @in_lib = false
      @strings = {} of StringKey => LLVM::Value
      @symbols = {} of String => Int32
      @symbol_table_values = [] of LLVM::Value
      program.symbols.each_with_index do |sym, index|
        @symbols[sym] = index
        @symbol_table_values << build_string_constant(sym, sym)
      end

      unless program.symbols.empty?
        symbol_table = define_symbol_table @llvm_mod
        symbol_table.initializer = LLVM.array(llvm_type(@program.string), @symbol_table_values)
      end

      @last = llvm_nil
      @fun_literal_count = 0

      # This flag is to generate less code. If there's an if in the middle
      # of a series of expressions we don't need the result, so there's no
      # need to build a phi for it.
      # Also, we don't need the value of unions returned from calls if they
      # are not going to be used.
      @needs_value = true

      @empty_md_list = metadata([] of Int32)
      @unused_fun_defs = [] of FunDef
      @proc_counts = Hash(String, Int32).new(0)

      @node_ensure_exception_handlers = {} of UInt64 => Handler

      @llvm_mod.data_layout = self.data_layout

      # We need to define __crystal_malloc and __crystal_realloc as soon as possible,
      # to avoid some memory being allocated with plain malloc.
      codgen_well_known_functions @node

      initialize_argv_and_argc

      initialize_simple_class_vars_and_constants

      alloca_vars @program.vars, @program
    end

    # Here we only initialize simple constants and class variables, those
    # that has simple values like 1, "foo" and other literals.
    def initialize_simple_class_vars_and_constants
      @program.class_var_and_const_initializers.each do |initializer|
        case initializer
        when Const
          next unless initializer.simple?

          initialize_simple_const(initializer)
        when ClassVarInitializer
          next unless initializer.node.simple_literal?

          class_var = initializer.owner.class_vars[initializer.name]
          next if class_var.thread_local?

          initialize_class_var(initializer.owner, initializer.name, initializer.meta_vars, initializer.node)
        end
      end
    end

    def wrap_builder(builder)
      CrystalLLVMBuilder.new builder, @program.printf(@llvm_mod)
    end

    def define_symbol_table(llvm_mod)
      llvm_mod.globals.add llvm_type(@program.string).array(@symbol_table_values.size), SYMBOL_TABLE_NAME
    end

    def data_layout
      @program.has_flag?("x86_64") ? DataLayout64 : DataLayout32
    end

    class CodegenWellKnownFunctions < Visitor
      @codegen : CodeGenVisitor

      def initialize(@codegen)
      end

      def visit(node : FileNode)
        true
      end

      def visit(node : Expressions)
        true
      end

      def visit(node : FunDef)
        case node.name
        when MALLOC_NAME, REALLOC_NAME, RAISE_NAME, PERSONALITY_NAME, GET_EXCEPTION_NAME
          @codegen.accept node
        end
        false
      end

      def visit(node : ASTNode)
        false
      end
    end

    def codgen_well_known_functions(node)
      visitor = CodegenWellKnownFunctions.new(self)
      node.accept visitor
    end

    def type
      context.type.not_nil!
    end

    def finish
      codegen_return @main_ret_type

      # If there are no instructions in the alloca block and the
      # const block, we just removed them (less noise)
      if alloca_block.instructions.empty?
        alloca_block.delete
      else
        br_block_chain alloca_block, entry_block
      end

      @unused_fun_defs.each do |node|
        codegen_fun node.real_name, node.external, @program, is_exported_fun: true
      end

      env_dump = ENV["DUMP"]?
      case env_dump
      when Nil
        # Nothing
      when "1"
        dump_all_llvm = true
      else
        dump_llvm_regex = Regex.new(env_dump)
      end

      @modules.each do |name, mod|
        if @debug
          add_compile_unit_metadata(mod, name == "" ? "main" : name)
        end

        mod.dump if dump_all_llvm || name =~ dump_llvm_regex
        # puts mod

        # Always run verifications so we can catch bugs earlier and more often.
        # We can probably remove this, or only enable this when compiling in
        # release mode, once we reach 1.0.
        mod.verify
      end
    end

    def visit(node : Attribute)
      false
    end

    def visit(node : FunDef)
      if @in_lib
        return false
      end

      unless node.external.dead?
        if node.external.used?
          codegen_fun node.real_name, node.external, @program, is_exported_fun: true
        else
          # If the fun is not invoked we codegen it at the end so
          # we don't have issues with constants being used before
          # they are declared.
          # But, apparenty, llvm requires us to define them so that
          # calls can find them, so we do so.
          codegen_fun node.real_name, node.external, @program, is_exported_fun: false
          @unused_fun_defs << node
        end
      end

      false
    end

    def visit(node : FileNode)
      with_context(Context.new(context.fun, context.type)) do
        file_module = @program.file_module(node.filename)
        if vars = file_module.vars?
          alloca_vars vars, file_module
        end
        node.node.accept self
      end

      false
    end

    def visit(node : Nop)
      @last = llvm_nil
    end

    def visit(node : NilLiteral)
      @last = llvm_nil
    end

    def visit(node : BoolLiteral)
      @last = int1(node.value ? 1 : 0)
    end

    def visit(node : CharLiteral)
      @last = int32(node.value.ord)
    end

    def visit(node : NumberLiteral)
      case node.kind
      when :i8
        @last = int8(node.value.to_i8)
      when :u8
        @last = int8(node.value.to_u8)
      when :i16
        @last = int16(node.value.to_i16)
      when :u16
        @last = int16(node.value.to_u16)
      when :i32
        @last = int32(node.value.to_i32)
      when :u32
        @last = int32(node.value.to_u32)
      when :i64
        @last = int64(node.value.to_i64)
      when :u64
        @last = int64(node.value.to_u64)
      when :f32
        @last = LLVM.float(node.value)
      when :f64
        @last = LLVM.double(node.value)
      end
    end

    def visit(node : StringLiteral)
      @last = build_string_constant(node.value, node.value)
    end

    def visit(node : SymbolLiteral)
      @last = int(@symbols[node.value])
    end

    def visit(node : TupleLiteral)
      request_value do
        type = node.type.as(TupleInstanceType)
        @last = allocate_tuple(type) do |tuple_type, i|
          exp = node.elements[i]
          exp.accept self
          {exp.type, @last}
        end
      end
      false
    end

    def visit(node : NamedTupleLiteral)
      request_value do
        type = node.type.as(NamedTupleInstanceType)
        struct_type = alloca llvm_type(type)
        node.entries.each do |entry|
          entry.value.accept self
          index = type.name_index(entry.key).not_nil!
          assign aggregate_index(struct_type, index), type.entries[index].type, entry.value.type, @last
        end
        @last = struct_type
      end
      false
    end

    def visit(node : PointerOf)
      @last = case node_exp = node.exp
              when Var
                context.vars[node_exp.name].pointer
              when InstanceVar
                instance_var_ptr (context.type.remove_typedef.as(InstanceVarContainer)), node_exp.name, llvm_self_ptr
              when ClassVar
                # Make sure the class var is initializer before taking a pointer of it
                if node_exp.var.initializer
                  initialize_class_var(node_exp)
                end
                get_global class_var_global_name(node_exp.var.owner, node_exp.var.name), node_exp.type, node_exp.var
              when Global
                get_global node_exp.name, node_exp.type, node_exp.var
              when Path
                # Make sure the constant is initialized before taking a pointer of it
                const = node_exp.target_const.not_nil!
                read_const_pointer(const)
              when ReadInstanceVar
                node_exp.obj.accept self
                instance_var_ptr (node_exp.obj.type), node_exp.name, @last
              else
                raise "Bug: #{node}"
              end
      false
    end

    def visit(node : ProcLiteral)
      fun_literal_name = fun_literal_name(node)
      is_closure = node.def.closure?

      # If we don't care about a proc literal's return type then we mark the associated
      # def as returning void. This can't be done in the type inference phase because
      # of bindings and type propagation.
      if node.force_nil?
        node.def.set_type @program.nil
      else
        # Use proc literal's type, which might have a broader type then the body
        # (for example, return type: Int32 | String, body: String)
        node.def.set_type node.return_type
      end

      the_fun = codegen_fun fun_literal_name, node.def, context.type, fun_module: @main_mod, is_fun_literal: true, is_closure: is_closure
      the_fun = check_main_fun fun_literal_name, the_fun

      fun_ptr = bit_cast(the_fun, LLVM::VoidPointer)
      if is_closure
        ctx_ptr = bit_cast(context.closure_ptr.not_nil!, LLVM::VoidPointer)
      else
        ctx_ptr = LLVM::VoidPointer.null
      end
      @last = make_fun node.type, fun_ptr, ctx_ptr

      false
    end

    def fun_literal_name(node : ProcLiteral)
      location = node.location.try &.original_location
      if location && (type = node.type?)
        proc_name = true
        filename = location.filename.as(String)
        fun_literal_name = Crystal.safe_mangling(@program, "~proc#{type}@#{Crystal.relative_filename(filename)}:#{location.line_number}")
      else
        proc_name = false
        fun_literal_name = "~fun_literal"
      end
      proc_count = @proc_counts[fun_literal_name]
      proc_count += 1
      @proc_counts[fun_literal_name] = proc_count

      if proc_count > 1
        if proc_name
          fun_literal_name = "#{fun_literal_name[0...5]}#{proc_count}#{fun_literal_name[5..-1]}"
        else
          fun_literal_name = "#{fun_literal_name}#{proc_count}"
        end
      end

      fun_literal_name
    end

    def visit(node : ProcPointer)
      owner = node.call.target_def.owner
      if obj = node.obj
        accept obj
        call_self = @last
      elsif owner.passed_as_self?
        call_self = llvm_self
      end

      last_fun = target_def_fun(node.call.target_def, owner)

      set_current_debug_location(node) if @debug
      fun_ptr = bit_cast(last_fun, LLVM::VoidPointer)
      if call_self && !owner.metaclass? && !owner.is_a?(LibType)
        ctx_ptr = bit_cast(call_self, LLVM::VoidPointer)
      else
        ctx_ptr = LLVM::VoidPointer.null
      end
      @last = make_fun node.type, fun_ptr, ctx_ptr

      false
    end

    def visit(node : Expressions)
      old_needs_value = @needs_value
      @needs_value = false

      last_index = node.expressions.size - 1
      node.expressions.each_with_index do |exp, i|
        @needs_value = true if old_needs_value && i == last_index
        accept exp
      end

      @needs_value = old_needs_value
      false
    end

    def visit(node : Return)
      node_type = accept_control_expression(node)

      codegen_return_node(node, node_type)

      false
    end

    def codegen_return_node(node, node_type)
      old_last = @last

      execute_ensures_until(node.target.as(Def))

      @last = old_last

      if return_phi = context.return_phi
        return_phi.add @last, node_type
      else
        codegen_return node_type
      end
    end

    def codegen_return(type : NoReturnType | Nil)
      unreachable
    end

    def codegen_return(type : Type)
      method_type = context.return_type.not_nil!
      if method_type.void?
        ret
      elsif method_type.nil_type?
        ret
      elsif method_type.no_return?
        unreachable
      else
        value = upcast(@last, method_type, type)
        ret to_rhs(value, method_type)
      end
    end

    def visit(node : ClassDef)
      node.runtime_initializers.try &.each &.accept self
      accept node.body
      @last = llvm_nil
      false
    end

    def visit(node : ModuleDef)
      accept node.body
      @last = llvm_nil
      false
    end

    def visit(node : LibDef)
      @in_lib = true
      node.body.accept self
      @in_lib = false
      @last = llvm_nil
      false
    end

    def visit(node : StructDef)
      @last = llvm_nil
      false
    end

    def visit(node : UnionDef)
      @last = llvm_nil
      false
    end

    def visit(node : EnumDef)
      node.members.each do |member|
        if member.is_a?(Assign)
          member.accept self
        end
      end

      @last = llvm_nil
      false
    end

    def visit(node : ExternalVar)
      @last = llvm_nil
      false
    end

    def visit(node : TypeDef)
      @last = llvm_nil
      false
    end

    def visit(node : Alias)
      @last = llvm_nil
      false
    end

    def visit(node : TypeOf)
      @last = type_id(node.type)
      false
    end

    def visit(node : SizeOf)
      @last = trunc(llvm_size(node.exp.type.instance_type), LLVM::Int32)
      false
    end

    def visit(node : InstanceSizeOf)
      @last = trunc(llvm_struct_size(node.exp.type.instance_type), LLVM::Int32)
      false
    end

    def visit(node : Include)
      node.runtime_initializers.try &.each &.accept self

      @last = llvm_nil
      false
    end

    def visit(node : Extend)
      node.runtime_initializers.try &.each &.accept self

      @last = llvm_nil
      false
    end

    def visit(node : If)
      then_block, else_block = new_blocks "then", "else"

      request_value do
        set_current_debug_location(node) if @debug
        codegen_cond_branch node.cond, then_block, else_block
      end

      Phi.open(self, node, @needs_value) do |phi|
        codegen_if_branch phi, node.then, then_block, false
        codegen_if_branch phi, node.else, else_block, true
      end

      false
    end

    def codegen_if_branch(phi, node, branch_block, last)
      position_at_end branch_block
      accept node
      phi.add @last, node.type?, last
    end

    def visit(node : While)
      set_ensure_exception_handler(node)

      with_cloned_context do
        while_block, body_block, exit_block = new_blocks "while", "body", "exit"

        context.while_block = while_block
        context.while_exit_block = exit_block
        context.break_phi = nil
        context.next_phi = nil

        br while_block

        position_at_end while_block

        request_value do
          set_current_debug_location node.cond if @debug
          codegen_cond_branch node.cond, body_block, exit_block
        end

        position_at_end body_block

        request_value(false) do
          accept node.body
        end
        br while_block

        position_at_end exit_block

        if node.no_returns?
          unreachable
        else
          @last = llvm_nil
        end
      end
      false
    end

    def codegen_cond_branch(node_cond, then_block, else_block)
      cond codegen_cond(node_cond), then_block, else_block

      nil
    end

    def codegen_cond(node : ASTNode)
      accept node
      codegen_cond node.type.remove_indirection
    end

    def visit(node : Not)
      accept node.exp
      @last = codegen_cond node.exp.type.remove_indirection
      @last = not @last
      false
    end

    def visit(node : Break)
      set_current_debug_location(node) if @debug
      node_type = accept_control_expression(node)

      if break_phi = context.break_phi
        old_last = @last
        execute_ensures_until(node.target.as(Call))
        @last = old_last

        break_phi.add @last, node_type
      elsif while_exit_block = context.while_exit_block
        execute_ensures_until(node.target.as(While))
        br while_exit_block
      else
        node.raise "Bug: unknown exit for break"
      end

      false
    end

    def visit(node : Next)
      set_current_debug_location(node) if @debug
      node_type = accept_control_expression(node)

      case target = node.target
      when Block
        if next_phi = context.next_phi
          old_last = @last
          execute_ensures_until(target.as(Block))
          @last = old_last

          next_phi.add @last, node_type
          return false
        end
      when While
        if while_block = context.while_block
          execute_ensures_until(target.as(While))
          br while_block
          return false
        end
      else
        # The only possibility is that we are in a captured block,
        # so this is the same as a return
        codegen_return_node(node, node_type)
        return false
      end

      node.raise "Bug: unknown exit for next"
    end

    def accept_control_expression(node)
      if exp = node.exp
        request_value do
          accept exp
        end
        exp.type? || @program.nil
      else
        @last = llvm_nil
        @program.nil
      end
    end

    def execute_ensures_until(node)
      stop_exception_handler = @node_ensure_exception_handlers[node.object_id]?.try &.node

      @ensure_exception_handlers.try &.reverse_each do |exception_handler|
        break if exception_handler.node.same?(stop_exception_handler)

        target_ensure = exception_handler.node.ensure
        next unless target_ensure

        with_context(exception_handler.context) do
          target_ensure.accept self
        end
      end
    end

    def set_ensure_exception_handler(node)
      if eh = @ensure_exception_handlers.try &.last?
        @node_ensure_exception_handlers[node.object_id] = eh
      end
    end

    def visit(node : Assign)
      return false if node.discarded?

      target, value = node.target, node.value

      case target
      when Underscore
        accept value
        return false
      when Path
        const = target.target_const.not_nil!
        if const.used? && !const.simple?
          initialize_const(const)
        end
        @last = llvm_nil
        return false
      end

      target_type = target.type?

      # This means it's an instance variable initialize of a generic type,
      # or a class variable initializer
      unless target_type
        if target.is_a?(ClassVar)
          # This is the case of a class var initializer
          initialize_class_var(target)
        end
        return false
      end

      # This is the case of an instance variable initializer
      if target.is_a?(InstanceVar) && !context.type.is_a?(InstanceVarContainer)
        return false
      end

      request_value do
        accept value
      end

      return if value.no_returns?

      last = @last

      set_current_debug_location node if @debug
      ptr = case target
            when InstanceVar
              instance_var_ptr (context.type.as(InstanceVarContainer)), target.name, llvm_self_ptr
            when Global
              get_global target.name, target_type, target.var
            when ClassVar
              read_class_var_ptr(target)
            when Var
              # Can't assign void
              return if target.type.void?

              # If assigning to a special variable in a method that yields,
              # assign to that variable too.
              check_assign_to_special_var_in_block(target, value)

              var = context.vars[target.name]?
              if var
                target_type = var.type
                var.pointer
              else
                target.raise "Bug: missing var #{target}"
              end
            else
              node.raise "Unknown assign target in codegen: #{target}"
            end

      @last = last

      if target.is_a?(Var) && target.special_var? && !target_type.reference_like?
        # For special vars that are not reference-like, the function argument will
        # be a pointer to the struct value. So, we need to first cast the value to
        # that type (without the pointer), load it, and store it in the argument.
        # If it's a reference-like then it's just a pointer and we can reuse the
        # logic in the other branch.
        upcasted_value = upcast @last, target_type, value.type
        store load(upcasted_value), ptr
      else
        assign ptr, target_type, value.type, @last
      end

      false
    end

    def check_assign_to_special_var_in_block(target, value)
      if (block_context = context.block_context?) && target.special_var?
        var = block_context.vars[target.name]
        assign var.pointer, var.type, value.type, @last
      end
    end

    def get_global(name, type, real_var, initial_value = nil)
      if real_var.thread_local?
        get_thread_local(name, type, real_var)
      else
        get_global_var(name, type, real_var, initial_value)
      end
    end

    def get_global_var(name, type, real_var, initial_value = nil)
      ptr = @llvm_mod.globals[name]?
      unless ptr
        llvm_type = llvm_type(type)

        thread_local = real_var.thread_local?

        # Declare global in this module as external
        ptr = @llvm_mod.globals.add(llvm_type, name)
        ptr.thread_local = true if thread_local

        if @llvm_mod == @main_mod
          ptr.initializer = initial_value || llvm_type.null
        else
          ptr.linkage = LLVM::Linkage::External

          # Define it in main if it's not already defined
          main_ptr = @main_mod.globals[name]?
          unless main_ptr
            main_ptr = @main_mod.globals.add(llvm_type, name)
            main_ptr.initializer = initial_value || llvm_type.null
            main_ptr.thread_local = true if thread_local
          end
        end
      end

      ptr
    end

    def get_thread_local(name, type, real_var)
      # If it's thread local, we use a NoInline function to access it
      # because of http://lists.llvm.org/pipermail/llvm-dev/2016-February/094736.html
      #
      # So, we basically make a function like this (assuming the global is a i32):
      #
      # define void @"*$foo"(i32**) noinline {
      #   store i32* @"$foo", i32** %0
      #   ret void
      # }
      #
      # And then in the caller we alloca an i32*, pass it, and then load the pointer,
      # which is the same as the global, but through a non-inlined function.
      #
      # Making a function that just returns the pointer doesn't work: LLVM inlines it.
      fun_name = "*#{name}"
      thread_local_fun = @main_mod.functions[fun_name]?
      unless thread_local_fun
        thread_local_fun = define_main_function(fun_name, [llvm_type(type).pointer.pointer], LLVM::Void) do |func|
          builder.store get_global_var(name, type, real_var), func.params[0]
          builder.ret
        end
        thread_local_fun.add_attribute LLVM::Attribute::NoInline
      end
      thread_local_fun = check_main_fun(fun_name, thread_local_fun)
      indirection_ptr = alloca llvm_type(type).pointer
      call thread_local_fun, indirection_ptr
      ptr = load indirection_ptr
    end

    def visit(node : TypeDeclaration)
      return false if node.discarded?

      var = node.var
      case var
      when Var
        declare_var var
      when Global
        if value = node.value
          request_value do
            accept value
          end

          ptr = get_global var.name, var.type, var.var
          assign ptr, var.type, value.type, @last
          return false
        end
      when ClassVar
        # This is the case of a class var initializer
        initialize_class_var(var)
      end

      @last = llvm_nil

      false
    end

    def visit(node : UninitializedVar)
      var = node.var
      if var.is_a?(Var)
        declare_var var
      end

      @last = llvm_nil

      false
    end

    def visit(node : Var)
      var = context.vars[node.name]?
      if var
        # Special variables always have an extra pointer
        already_loaded = (node.special_var? ? false : var.already_loaded)
        @last = downcast var.pointer, node.type, var.type, already_loaded
      elsif node.name == "self"
        if node.type.metaclass?
          @last = type_id(node.type)
        else
          @last = downcast llvm_self_ptr, node.type, context.type, true
        end
      else
        node.raise "Bug: missing context var: #{node.name}"
      end
    end

    def visit(node : Global)
      read_global node.name.to_s, node.type, node.var
    end

    def visit(node : ClassVar)
      @last = read_class_var(node)
    end

    def read_global(name, type, real_var)
      @last = get_global name, type, real_var
      @last = to_lhs @last, type
    end

    def visit(node : InstanceVar)
      read_instance_var node.type, context.type, node.name, llvm_self_ptr
    end

    def end_visit(node : ReadInstanceVar)
      read_instance_var node.type, node.obj.type, node.name, @last
    end

    def read_instance_var(node_type, type, name, value)
      ivar = type.lookup_instance_var_with_owner(name).instance_var
      ivar_ptr = instance_var_ptr type, name, value
      @last = downcast ivar_ptr, node_type, ivar.type, false
      if type.is_a?(CStructOrUnionType)
        # When reading the instance variable of a C struct or union
        # we need to convert C functions to Crystal procs. This
        # can happen for example in Struct#to_s, where all fields
        # are inspected.
        @last = check_c_fun node_type, @last
      end
      false
    end

    def visit(node : Cast)
      request_value do
        accept node.obj
      end

      last_value = @last

      obj_type = node.obj.type
      to_type = node.to.type.virtual_type

      if to_type.pointer?
        if obj_type.nil_type?
          @last = llvm_type(to_type).null
        else
          @last = cast_to last_value, to_type
        end
      elsif obj_type.pointer?
        @last = cast_to last_value, to_type
      else
        resulting_type = node.type
        if node.upcast?
          @last = upcast last_value, resulting_type, obj_type
        elsif obj_type != resulting_type
          type_id = type_id last_value, obj_type
          cmp = match_type_id obj_type, resulting_type, type_id

          matches_block, doesnt_match_block = new_blocks "matches", "doesnt_match"
          cond cmp, matches_block, doesnt_match_block

          position_at_end doesnt_match_block

          temp_var_name = @program.new_temp_var_name
          context.vars[temp_var_name] = LLVMVar.new(last_value, obj_type, already_loaded: true)
          accept type_cast_exception_call(obj_type, to_type, node, temp_var_name)
          context.vars.delete temp_var_name

          position_at_end matches_block
          @last = downcast last_value, resulting_type, obj_type, true
        end
      end

      false
    end

    def visit(node : NilableCast)
      request_value do
        accept node.obj
      end

      last_value = @last

      obj_type = node.obj.type
      to_type = node.to.type

      resulting_type = node.type
      non_nilable_type = node.non_nilable_type

      if node.upcast?
        @last = upcast last_value, non_nilable_type, obj_type
        @last = upcast @last, resulting_type, non_nilable_type
      elsif obj_type != non_nilable_type
        type_id = type_id last_value, obj_type
        cmp = match_type_id obj_type, non_nilable_type, type_id

        Phi.open(self, node, @needs_value) do |phi|
          matches_block, doesnt_match_block = new_blocks "matches", "doesnt_match"
          cond cmp, matches_block, doesnt_match_block

          position_at_end doesnt_match_block
          @last = upcast llvm_nil, resulting_type, @program.nil
          phi.add @last, resulting_type

          position_at_end matches_block
          @last = downcast last_value, non_nilable_type, obj_type, true
          @last = upcast @last, resulting_type, non_nilable_type
          phi.add @last, resulting_type, last: true
        end
      else
        @last = upcast last_value, resulting_type, obj_type
      end

      false
    end

    def type_cast_exception_call(from_type, to_type, node, var_name)
      pieces = [
        StringLiteral.new("cast from "),
        Call.new(Var.new(var_name), "class"),
        StringLiteral.new(" to #{to_type} failed"),
      ] of ASTNode

      if location = node.location
        pieces << StringLiteral.new (", at #{location.filename}:#{location.line_number}")
      end

      ex = Call.new(Path.global("TypeCastError"), "new", StringInterpolation.new(pieces))
      call = Call.global("raise", ex)
      call = @program.normalize(call)

      meta_vars = MetaVars.new
      meta_vars[var_name] = MetaVar.new(var_name, type: from_type)
      visitor = MainVisitor.new(@program, meta_vars)
      @program.visit_main call, visitor: visitor
      call
    end

    def cant_pass_closure_to_c_exception_call
      @cant_pass_closure_to_c_exception_call ||= begin
        call = Call.global("raise", StringLiteral.new("passing a closure to C is not allowed"))
        @program.visit_main call
        call
      end
    end

    def visit(node : IsA)
      codegen_type_filter node, &.filter_by(node.const.type)
    end

    def visit(node : RespondsTo)
      codegen_type_filter node, &.filter_by_responds_to(node.name)
    end

    def codegen_type_filter(node)
      accept node.obj
      obj_type = node.obj.type

      type_id = type_id @last, obj_type
      filtered_type = yield(obj_type).not_nil!

      @last = match_type_id obj_type, filtered_type, type_id

      false
    end

    def declare_var(var)
      return if var.no_returns?

      context.vars[var.name] ||= LLVMVar.new(alloca(llvm_type(var.type), var.name), var.type)
    end

    def declare_lib_var(name, type, thread_local)
      var = @llvm_mod.globals[name]?
      unless var
        var = llvm_mod.globals.add(llvm_c_return_type(type), name)
        var.linkage = LLVM::Linkage::External
        var.thread_local = thread_local
      end
      var
    end

    def visit(node : Def)
      node.runtime_initializers.try &.each &.accept self

      @last = llvm_nil
      false
    end

    def visit(node : Macro)
      @last = llvm_nil
      false
    end

    def visit(node : Path)
      if const = node.target_const
        read_const(const)
      elsif replacement = node.syntax_replacement
        accept replacement
      else
        node_type = node.type
        # Special case: if the type is a type tuple we need to create a tuple for it
        if node_type.is_a?(TupleInstanceType)
          @last = allocate_tuple(node_type) do |tuple_type, i|
            {tuple_type, type_id(tuple_type)}
          end
        else
          @last = type_id(node.type)
        end
      end
      false
    end

    def visit(node : Generic)
      @last = type_id(node.type)
      false
    end

    def visit(node : Yield)
      if node.expanded
        raise "Bug: #{node} at #{node.location} should have been expanded"
      end

      block_context = context.block_context.not_nil!
      block = context.block
      splat_index = block.splat_index

      closured_vars = closured_vars(block.vars, block)

      malloc_closure closured_vars, block_context, block_context.closure_parent_context

      old_scope = block_context.vars["%scope"]?

      if node_scope = node.scope
        request_value do
          accept node_scope
        end
        block_context.vars["%scope"] = LLVMVar.new(@last, node_scope.type)
      end

      # First accept all yield expressions and assign them to block vars
      i = 0
      unless node.exps.empty?
        exp_values = Array({LLVM::Value, Type}).new(node.exps.size)

        # We first accept the expressions and store the values, without
        # assigning them to the block vars yet because we might have
        # a nested yield that would override a block argument's value
        node.exps.each_with_index do |exp, i|
          request_value do
            accept exp
          end

          if exp.is_a?(Splat)
            tuple_type = exp.type.as(TupleInstanceType)
            tuple_type.tuple_types.each_with_index do |subtype, j|
              exp_values << {codegen_tuple_indexer(tuple_type, @last, j), subtype}
            end
          else
            exp_values << {@last, exp.type}
          end
        end

        # Now assign exp values to block arguments
        if splat_index
          j = 0
          block.args.each_with_index do |arg, i|
            block_var = block_context.vars[arg.name]
            if i == splat_index
              exp_value = allocate_tuple(arg.type.as(TupleInstanceType)) do |tuple_type|
                exp_value2, exp_type = exp_values[j]
                j += 1
                {exp_type, exp_value2}
              end
              exp_type = arg.type
            else
              exp_value, exp_type = exp_values[j]
              j += 1
            end
            assign block_var.pointer, block_var.type, exp_type, exp_value
          end
        else
          # Check if tuple unpacking is needed
          if exp_values.size == 1 &&
             (exp_type = exp_values.first[1]).is_a?(TupleInstanceType) &&
             block.args.size > 1
            exp_value = exp_values.first[0]
            exp_type.tuple_types.each_with_index do |tuple_type, i|
              arg = block.args[i]?
              if arg
                t_type = tuple_type
                t_value = codegen_tuple_indexer(exp_type, exp_value, i)
                block_var = block_context.vars[arg.name]
                assign block_var.pointer, block_var.type, t_type, t_value
              end
            end
          else
            exp_values.each_with_index do |(exp_value, exp_type), i|
              if arg = block.args[i]?
                block_var = block_context.vars[arg.name]
                assign block_var.pointer, block_var.type, exp_type, exp_value
              end
            end
          end
        end
      end

      Phi.open(self, block, @needs_value) do |phi|
        with_cloned_context(block_context) do |old|
          # Reset those vars that are declared inside the block and are nilable.
          reset_block_vars block

          context.break_phi = old.return_phi
          context.next_phi = phi
          context.while_exit_block = nil
          context.closure_parent_context = block_context.closure_parent_context

          @needs_value = true
          set_ensure_exception_handler(block)

          accept block.body
        end

        phi.add_last @last, block.body.type?
      end

      if old_scope
        block_context.vars["%scope"] = old_scope
      end

      false
    end

    def visit(node : ExceptionHandler)
      rescue_block = new_block "rescue"

      node_rescues = node.rescues
      node_ensure = node.ensure
      rescue_ensure_block = nil

      Phi.open(self, node, @needs_value) do |phi|
        exception_handler = Handler.new(node, context)

        ensure_exception_handlers = (@ensure_exception_handlers ||= [] of Handler)
        ensure_exception_handlers.push exception_handler

        old_rescue_block = @rescue_block
        @rescue_block = rescue_block
        accept node.body
        @rescue_block = old_rescue_block

        if node_else = node.else
          accept node_else
          phi.add @last, node_else.type?
        else
          phi.add @last, node.body.type?
        end

        position_at_end rescue_block
        lp_ret_type = llvm_typer.landing_pad_type
        lp = builder.landing_pad lp_ret_type, main_fun(PERSONALITY_NAME), [] of LLVM::Value
        unwind_ex_obj = extract_value lp, 0
        ex_type_id = extract_value lp, 1

        if node_rescues
          if node_ensure
            rescue_ensure_block = new_block "rescue_ensure"
          end

          node_rescues.each do |a_rescue|
            this_rescue_block, next_rescue_block = new_blocks "this_rescue", "next_rescue"
            if a_rescue_types = a_rescue.types
              cond = nil
              a_rescue_types.each do |type|
                rescue_type = type.type.instance_type.virtual_type
                rescue_type_cond = match_any_type_id(rescue_type, ex_type_id)
                cond = cond ? or(cond, rescue_type_cond) : rescue_type_cond
              end
              cond cond.not_nil!, this_rescue_block, next_rescue_block
            else
              br this_rescue_block
            end
            position_at_end this_rescue_block

            with_cloned_context do
              if a_rescue_name = a_rescue.name
                context.vars = context.vars.dup
                get_exception_fun = main_fun(GET_EXCEPTION_NAME)
                exception_ptr = call get_exception_fun, [bit_cast(unwind_ex_obj, get_exception_fun.params.first.type)]
                exception = int2ptr exception_ptr, LLVMTyper::TYPE_ID_POINTER
                unless a_rescue.type.virtual?
                  exception = cast_to exception, a_rescue.type
                end
                var = context.vars[a_rescue_name]
                assign var.pointer, var.type, a_rescue.type, exception
              end

              # Make sure the rescue knows about the current ensure
              # and the previous catch block
              old_rescue_block = @rescue_block
              @rescue_block = rescue_ensure_block || @rescue_block

              accept a_rescue.body

              @rescue_block = old_rescue_block
            end
            phi.add @last, a_rescue.body.type?

            position_at_end next_rescue_block
          end
        end

        ensure_exception_handlers.pop

        if node_ensure
          accept node_ensure
        end

        raise_fun = main_fun(RAISE_NAME)
        codegen_call_or_invoke(node, nil, nil, raise_fun, [bit_cast(unwind_ex_obj, raise_fun.params.first.type)], true, @program.no_return)
      end

      old_last = @last
      builder_end = @builder.end

      if node_ensure && !builder_end
        accept node_ensure
      end

      if node_ensure && node_rescues
        old_block = insert_block
        position_at_end rescue_ensure_block.not_nil!
        lp_ret_type = llvm_typer.landing_pad_type
        lp = builder.landing_pad lp_ret_type, main_fun(PERSONALITY_NAME), [] of LLVM::Value
        unwind_ex_obj = extract_value lp, 0

        accept node_ensure
        raise_fun = main_fun(RAISE_NAME)
        codegen_call_or_invoke(node, nil, nil, raise_fun, [bit_cast(unwind_ex_obj, raise_fun.params.first.type)], true, @program.no_return)

        position_at_end old_block

        # Since we went to another block, we must restore the 'end' state
        @builder.end = builder_end
      end

      @last = old_last

      false
    end

    def check_proc_is_not_closure(value, type)
      check_fun_name = "~check_proc_is_not_closure"
      func = @main_mod.functions[check_fun_name]? || create_check_proc_is_not_closure_fun(check_fun_name)
      func = check_main_fun check_fun_name, func
      value = call func, [value] of LLVM::Value
      bit_cast value, llvm_proc_type(type)
    end

    def create_check_proc_is_not_closure_fun(fun_name)
      define_main_function(fun_name, [LLVMTyper::PROC_TYPE], LLVM::VoidPointer) do |func|
        param = func.params.first

        fun_ptr = extract_value param, 0
        ctx_ptr = extract_value param, 1

        ctx_is_null_block = new_block "ctx_is_null"
        ctx_is_not_null_block = new_block "ctx_is_not_null"

        ctx_is_null = equal? ctx_ptr, LLVM::VoidPointer.null
        cond ctx_is_null, ctx_is_null_block, ctx_is_not_null_block

        position_at_end ctx_is_null_block
        ret fun_ptr

        position_at_end ctx_is_not_null_block
        accept cant_pass_closure_to_c_exception_call
      end
    end

    def make_fun(type, fun_ptr, ctx_ptr)
      closure_ptr = alloca llvm_type(type)
      store fun_ptr, gep(closure_ptr, 0, 0)
      store ctx_ptr, gep(closure_ptr, 0, 1)
      load(closure_ptr)
    end

    def make_nilable_fun(type)
      null = LLVM::VoidPointer.null
      make_fun type, null, null
    end

    def define_main_function(name, arg_types, return_type, needs_alloca = false)
      old_builder = self.builder
      old_llvm_mod = @llvm_mod
      old_fun = context.fun
      old_ensure_exception_handlers = @ensure_exception_handlers
      old_rescue_block = @rescue_block
      old_entry_block = @entry_block
      old_alloca_block = @alloca_block
      old_needs_value = @needs_value
      @llvm_mod = @main_mod
      @ensure_exception_handlers = nil
      @rescue_block = nil

      a_fun = @main_mod.functions.add(name, arg_types, return_type) do |func|
        context.fun = func
        context.fun.linkage = LLVM::Linkage::Internal if @single_module
        if needs_alloca
          builder = LLVM::Builder.new
          @builder = wrap_builder builder
          new_entry_block
          yield func
          br_from_alloca_to_entry
        else
          func.basic_blocks.append "entry" do |builder|
            @builder = wrap_builder builder
            yield func
          end
        end
      end

      @builder = old_builder
      @llvm_mod = old_llvm_mod
      @ensure_exception_handlers = old_ensure_exception_handlers
      @rescue_block = old_rescue_block
      @entry_block = old_entry_block
      @alloca_block = old_alloca_block
      @needs_value = old_needs_value
      context.fun = old_fun

      a_fun
    end

    def llvm_self(type = context.type)
      self_var = context.vars["self"]?
      if self_var
        downcast self_var.pointer, type, self_var.type, true
      else
        type_id(type.not_nil!)
      end
    end

    def llvm_self_ptr
      type = context.type
      if type.is_a?(VirtualType)
        if type.struct?
          # A virtual struct doesn't need a cast to a more generic pointer
          # (it's the union already)
          llvm_self
        else
          cast_to llvm_self, type.base_type
        end
      else
        llvm_self
      end
    end

    def new_entry_block
      @alloca_block, @entry_block = new_entry_block_chain "alloca", "entry"
    end

    def new_entry_block_chain(*names)
      blocks = new_blocks *names
      position_at_end blocks.last
      blocks
    end

    def br_from_alloca_to_entry
      # If there are no instructions in the alloca we can delete
      # it and just keep the entry block (less noise).
      if alloca_block.instructions.empty?
        alloca_block.delete
      else
        br_block_chain alloca_block, entry_block
      end
    end

    def br_block_chain(*blocks)
      old_block = insert_block

      0.upto(blocks.size - 2) do |i|
        position_at_end blocks[i]
        clear_current_debug_location if @debug
        br blocks[i + 1]
      end

      position_at_end old_block
    end

    def new_block(name = "")
      context.fun.basic_blocks.append name
    end

    def new_blocks(*names)
      names.map { |name| new_block name }
    end

    def alloca_vars(vars, obj = nil, args = nil, parent_context = nil)
      self_closured = obj.is_a?(Def) && obj.self_closured?
      closured_vars = closured_vars(vars, obj)
      alloca_non_closured_vars(vars, obj, args)
      malloc_closure closured_vars, context, parent_context, self_closured
    end

    def alloca_non_closured_vars(vars, obj = nil, args = nil)
      return unless vars

      in_alloca_block do
        # Allocate all variables which are not closured and don't belong to an outer closure
        vars.each do |name, var|
          next if name == "self" || context.vars[name]?

          var_type = var.type? || @program.nil

          if var_type.void?
            context.vars[name] = LLVMVar.new(llvm_nil, @program.void)
          elsif var_type.no_return?
            # No alloca for NoReturn
          elsif var.closure_in?(obj)
            # We deal with closured vars later
          elsif !obj || var.belongs_to?(obj)
            # We deal with arguments later
            is_arg = args.try &.any? { |arg| arg.name == var.name }
            next if is_arg

            ptr = builder.alloca llvm_type(var_type), name
            context.vars[name] = LLVMVar.new(ptr, var_type)

            # Assign default nil for variables that are bound to the nil variable
            if bound_to_mod_nil?(var)
              assign ptr, var_type, @program.nil, llvm_nil
            end
          else
            # The variable belong to an outer closure
          end
        end
      end
    end

    def closured_vars(vars, obj = nil)
      return unless vars

      closure_vars = nil

      vars.each_value do |var|
        # It might be the case that a closured variable ends up without
        # a type, as in #2196, because a branch can't be typed and is
        # finally removed before codegen. In that case we just assume
        # Nil as a type.
        if var.closure_in?(obj) && var.type?
          closure_vars ||= [] of MetaVar
          closure_vars << var
        end
      end

      closure_vars
    end

    def malloc_closure(closure_vars, current_context, parent_context = nil, self_closured = false)
      parent_closure_type = parent_context.try &.closure_type

      if closure_vars || self_closured
        closure_vars ||= [] of MetaVar
        closure_type = @llvm_typer.closure_context_type(closure_vars, parent_closure_type, (self_closured ? current_context.type : nil))
        closure_ptr = malloc closure_type
        closure_vars.each_with_index do |var, i|
          current_context.vars[var.name] = LLVMVar.new(gep(closure_ptr, 0, i, var.name), var.type)
        end
        closure_skip_parent = false

        if parent_closure_type
          store parent_context.not_nil!.closure_ptr.not_nil!, gep(closure_ptr, 0, closure_vars.size, "parent")
        end

        if self_closured
          offset = parent_closure_type ? 1 : 0
          self_value = llvm_self
          self_value = load self_value if current_context.type.passed_by_value?

          store self_value, gep(closure_ptr, 0, closure_vars.size + offset, "self")

          current_context.closure_self = current_context.type
        end
      elsif parent_context && parent_context.closure_type
        closure_vars = parent_context.closure_vars
        closure_type = parent_context.closure_type
        closure_ptr = parent_context.closure_ptr
        closure_skip_parent = true
      else
        closure_skip_parent = false
      end

      current_context.closure_vars = closure_vars
      current_context.closure_type = closure_type
      current_context.closure_ptr = closure_ptr
      current_context.closure_skip_parent = closure_skip_parent
    end

    def undef_vars(vars, obj)
      return unless vars

      vars.each do |name, var|
        # Don't remove special vars because they are local for the entire method
        if var.belongs_to?(obj) && !var.special_var?
          context.vars.delete(name)
        end
      end
    end

    def reset_block_vars(block)
      vars = block.vars
      return unless vars

      vars.each do |name, var|
        if var.context == block && bound_to_mod_nil?(var)
          context_var = context.vars[name]
          assign context_var.pointer, context_var.type, @program.nil, llvm_nil
        end
      end
    end

    def bound_to_mod_nil?(var)
      var.dependencies.any? &.same?(@program.nil_var)
    end

    def alloca(type, name = "")
      in_alloca_block { builder.alloca type, name }
    end

    def in_alloca_block
      old_block = insert_block
      position_at_end alloca_block
      value = yield
      position_at_end old_block
      value
    end

    def in_const_block(container)
      old_llvm_mod = @llvm_mod
      @llvm_mod = @main_mod

      old_ensure_exception_handlers = @ensure_exception_handlers
      old_rescue_block = @rescue_block
      @ensure_exception_handlers = nil
      @rescue_block = nil

      with_cloned_context do
        context.fun = @main

        # "self" in a constant is the constant's container
        context.type = container

        # Start with fresh variables
        context.vars = LLVMVars.new

        yield
      end

      @llvm_mod = old_llvm_mod
      @ensure_exception_handlers = old_ensure_exception_handlers
      @rescue_block = old_rescue_block
    end

    def printf(format, args = [] of LLVM::Value)
      call @program.printf(@llvm_mod), [builder.global_string_pointer(format)] + args
    end

    def allocate_aggregate(type)
      struct_type = llvm_struct_type(type)
      if type.passed_by_value?
        @last = alloca struct_type
      else
        @last = malloc struct_type
      end
      memset @last, int8(0), struct_type.size
      type_ptr = @last
      run_instance_vars_initializers(type, type, type_ptr)
      @last = type_ptr
    end

    def allocate_tuple(type)
      struct_type = alloca llvm_type(type)
      type.tuple_types.each_with_index do |tuple_type, i|
        exp_type, value = yield tuple_type, i
        assign aggregate_index(struct_type, i), tuple_type, exp_type, value
      end
      struct_type
    end

    def run_instance_vars_initializers(real_type, type : GenericClassInstanceType, type_ptr)
      run_instance_vars_initializers(real_type, type.generic_class, type_ptr)
      run_instance_vars_initializers_non_recursive real_type, type, type_ptr
    end

    def run_instance_vars_initializers(real_type, type : InheritedGenericClass, type_ptr)
      run_instance_vars_initializers real_type, type.extended_class, type_ptr
    end

    def run_instance_vars_initializers(real_type, type : ClassType | GenericClassType, type_ptr)
      if superclass = type.superclass
        run_instance_vars_initializers(real_type, superclass, type_ptr)
      end

      return if type.is_a?(GenericClassType)

      run_instance_vars_initializers_non_recursive real_type, type, type_ptr
    end

    def run_instance_vars_initializers(real_type, type : Type, type_ptr)
      # Nothing to do
    end

    def run_instance_vars_initializers_non_recursive(real_type, type, type_ptr)
      initializers = type.instance_vars_initializers
      return unless initializers

      initializers.each do |init|
        ivar = real_type.lookup_instance_var(init.name)
        value = init.value

        # Don't need to initialize false
        if ivar.type == @program.bool && value.false?
          next
        end

        # Don't need to initialize zero
        if ivar.type == @program.int32 && value.zero?
          next
        end

        with_cloned_context do
          # Instance var initializers must run with "self"
          # properly set up to the type being allocated
          context.type = real_type
          context.vars = LLVMVars.new
          context.vars["self"] = LLVMVar.new(type_ptr, real_type)
          alloca_vars init.meta_vars

          value.accept self

          ivar_ptr = instance_var_ptr real_type, init.name, type_ptr
          assign ivar_ptr, ivar.type, value.type, @last
        end
      end
    end

    def malloc(type)
      @malloc_fun ||= @main_mod.functions[MALLOC_NAME]?
      if malloc_fun = @malloc_fun
        malloc_fun = check_main_fun MALLOC_NAME, malloc_fun
        size = trunc(type.size, LLVM::Int32)
        pointer = call malloc_fun, size
        bit_cast pointer, type.pointer
      else
        builder.malloc type
      end
    end

    def array_malloc(type, count)
      @malloc_fun ||= @main_mod.functions[MALLOC_NAME]?
      size = trunc(type.size, LLVM::Int32)
      count = trunc(count, LLVM::Int32)
      size = builder.mul size, count
      if malloc_fun = @malloc_fun
        malloc_fun = check_main_fun MALLOC_NAME, malloc_fun
        pointer = call malloc_fun, size
        memset pointer, int8(0), size
        bit_cast pointer, type.pointer
      else
        pointer = builder.array_malloc(type, count)
        void_pointer = bit_cast pointer, LLVM::VoidPointer
        memset void_pointer, int8(0), size
        pointer
      end
    end

    def memset(pointer, value, size)
      pointer = cast_to_void_pointer pointer
      call @program.memset(@llvm_mod), [pointer, value, trunc(size, LLVM::Int32), int32(4), int1(0)]
    end

    def memcpy(dest, src, len, align, volatile)
      call @program.memcpy(@llvm_mod), [dest, src, len, align, volatile]
    end

    def realloc(buffer, size)
      @realloc_fun ||= @main_mod.functions[REALLOC_NAME]?
      if realloc_fun = @realloc_fun
        realloc_fun = check_main_fun REALLOC_NAME, realloc_fun
        size = trunc(size, LLVM::Int32)
        call realloc_fun, [buffer, size]
      else
        call @program.realloc(@llvm_mod), [buffer, size]
      end
    end

    def to_lhs(value, type)
      type.passed_by_value? ? value : load value
    end

    def to_rhs(value, type)
      type.passed_by_value? ? load value : value
    end

    def union_type_id(union_pointer)
      aggregate_index union_pointer, 0
    end

    def union_value(union_pointer)
      aggregate_index union_pointer, 1
    end

    def aggregate_index(ptr, index)
      gep ptr, 0, index
    end

    def instance_var_ptr(type, name, pointer)
      index = type.index_of_instance_var(name)

      unless type.struct?
        index += 1
      end

      if type.is_a?(VirtualType)
        if type.struct?
          if type.remove_indirection.is_a?(UnionType)
            # For a struct we need to cast the second part of the union to the base type
            value_ptr = gep(pointer, 0, 1)
            pointer = bit_cast value_ptr, llvm_type(type.base_type).pointer
          else
            # Nothing, there's only one subclass so it's the struct already
          end
        else
          pointer = cast_to pointer, type.base_type
        end
      end

      aggregate_index pointer, index
    end

    def build_string_constant(str, name = "str")
      name = "#{name[0..18]}..." if name.bytesize > 18
      name = name.gsub '@', '.'
      name = "'#{name}'"
      key = StringKey.new(@llvm_mod, str)
      @strings[key] ||= begin
        global = @llvm_mod.globals.add(@llvm_typer.llvm_string_type(str.bytesize), name)
        global.linkage = LLVM::Linkage::Private
        global.global_constant = true
        global.initializer = LLVM.struct [
          type_id(@program.string),
          int32(str.bytesize),
          int32(str.size),
          LLVM.string(str),
        ]
        cast_to global, @program.string
      end
    end

    def request_value(request = true)
      old_needs_value = @needs_value
      @needs_value = request
      begin
        yield
      ensure
        @needs_value = old_needs_value
      end
    end

    def accept(node)
      node.accept self
    end

    def visit(node : ExpandableNode)
      raise "Bug: #{node} at #{node.location} should have been expanded"
    end

    def visit(node : ASTNode)
      true
    end
  end

  def self.safe_mangling(program, name)
    if program.has_flag?("windows")
      name.gsub do |char|
        case char
        when '<', '>', '(', ')', '*', ':', ',', '#', '@', ' '
          "."
        when '+'
          ".."
        else
          char
        end
      end
    else
      name
    end
  end

  class Program
    def sprintf(llvm_mod)
      llvm_mod.functions["sprintf"]? || llvm_mod.functions.add("sprintf", [LLVM::VoidPointer], LLVM::Int32, true)
    end

    def printf(llvm_mod)
      llvm_mod.functions["printf"]? || llvm_mod.functions.add("printf", [LLVM::VoidPointer], LLVM::Int32, true)
    end

    def realloc(llvm_mod)
      llvm_mod.functions["realloc"]? || llvm_mod.functions.add("realloc", ([LLVM::VoidPointer, LLVM::Int64]), LLVM::VoidPointer)
    end

    def memset(llvm_mod)
      llvm_mod.functions["llvm.memset.p0i8.i32"]? || llvm_mod.functions.add("llvm.memset.p0i8.i32", [LLVM::VoidPointer, LLVM::Int8, LLVM::Int32, LLVM::Int32, LLVM::Int1], LLVM::Void)
    end

    def memcpy(llvm_mod)
      llvm_mod.functions["llvm.memcpy.p0i8.p0i8.i32"]? || llvm_mod.functions.add("llvm.memcpy.p0i8.p0i8.i32", [LLVM::VoidPointer, LLVM::VoidPointer, LLVM::Int32, LLVM::Int32, LLVM::Int1], LLVM::Void)
    end
  end
end

require "./*"
