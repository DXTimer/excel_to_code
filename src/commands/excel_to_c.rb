# coding: utf-8
require_relative 'excel_to_x'
require 'ffi'

class ExcelToC < ExcelToX
  
  def language
    "c"
  end
  
  # These actually create the code version of the excel
  def write_code
    write_out_excel_as_code
    write_build_script
    write_fuby_ffi_interface
    write_tests
  end
    
  def write_out_excel_as_code
        
    all_refs = all_formulae
    
    number_of_refs = 0
        
    # Output the workbook preamble
    w = input('Worksheet C names')
    o = output("#{output_name.downcase}.c")
    o.puts "// #{excel_file} approximately translated into C"

    o.puts '// First we have c versions of all the excel functions that we know'
    o.puts IO.readlines(File.join(File.dirname(__FILE__),'..','compile','c','excel_to_c_runtime.c')).join
    o.puts '// End of the generic c functions'
    o.puts 
    o.puts '// Start of the file specific functions'
    o.puts
    
    # Now we have to put all the initial definitions out
    o.puts "// definitions"

    i = input("Common elements")
    c = CompileToCHeader.new
    c.gettable = lambda { |ref| false }
    c.rewrite(i,w,o)
    i.rewind
    number_of_refs += i.lines.to_a.size
    close(i)

    worksheets do |name,xml_filename|
      w.rewind
      c = CompileToCHeader.new
      c.settable = settable(name)
      c.gettable = gettable(name)
      c.worksheet = name
      i = input([name,"Formulae"])
      c.rewrite(i,w,o)
      i.rewind
      number_of_refs += i.lines.to_a.size
      close(i)
    end
    
    o.puts "// end of definitions"
    o.puts
    o.puts "// Used to decide whether to recalculate a cell"
    o.puts "static int variable_set[#{number_of_refs}];"
    o.puts "void reset() {"
    o.puts "  int i;"
    o.puts "  cell_counter = 0;"
    o.puts "  for(i = 0; i < #{number_of_refs}; i++) {"
    o.puts "    variable_set[i] = 0;"
    o.puts "  }"
    o.puts "};"
    o.puts
    
    # Output the value constants
    o.puts "// starting the value constants"
    mapper = MapValuesToCStructs.new
    i = input("Constants")
    i.lines do |line|
      begin
        ref, formula = line.split("\t")
        ast = eval(formula)
        calculation = mapper.map(ast)
        o.puts "static ExcelValue #{ref} = #{calculation};"
      rescue Exception => e
        puts "Exception at line #{line}"
        raise
      end
    end          
    close(i)
    o.puts "// ending the value constants"
    o.puts
    
    variable_set_counter = 0
    
    # output the common elements
    o.puts "// starting common elements"
    w.rewind
    c = CompileToC.new
    c.variable_set_counter = variable_set_counter
    c.gettable = lambda { |ref| false }
    i = input("Common elements")
    c.rewrite(i,w,o)
    close(i)
    o.puts "// ending common elements"
    o.puts
    
    variable_set_counter = c.variable_set_counter
    
    c = CompileToC.new
    c.variable_set_counter = variable_set_counter
    # Output the elements from each worksheet in turn
    worksheets do |name,xml_filename|
      w.rewind
      c.settable = settable(name)
      c.gettable = gettable(name)
      c.worksheet = name

      i = input([name,"Formulae"])
      o.puts "// start #{name}"
      c.rewrite(i,w,o)
      o.puts "// end #{name}"
      o.puts
      close(i)
    end
    close(w,o)
  end
  
  # FIXME: Should make a Rakefile, especially in order to make sure the dynamic library name
  # is set properly
  def write_build_script
    o = output("Makefile")
    name = output_name.downcase
    
    # Target for shared library
    dynamic_library_name = FFI.map_library_name(name)
    o.puts "#{dynamic_library_name}: #{name}.o"
    o.puts "\tgcc -shared -o #{dynamic_library_name} #{name}.o"
    o.puts
    
    # Target for compiled version
    o.puts "#{name}.o:"
    o.puts "\tgcc -Wall -fPIC -c #{name}.c"
    o.puts
    
    # Target for cleaning
    o.puts "clean:"
    o.puts "\trm #{name}.o"
    o.puts "\trm #{dynamic_library_name}"
    
    close(o)
  end
  
  def write_fuby_ffi_interface
    all_formulae = all_formulae()
    name = output_name.downcase
    o = output("#{name}.rb")
      
    code = <<END
require 'ffi'

module #{ruby_module_name}
  extend FFI::Library
  ffi_lib  File.join(File.dirname(__FILE__),FFI.map_library_name('#{name}'))
  ExcelType = enum :ExcelEmpty, :ExcelNumber, :ExcelString, :ExcelBoolean, :ExcelError, :ExcelRange
                
  class ExcelValue < FFI::Struct
    layout :type, ExcelType,
  	       :number, :double,
  	       :string, :string,
         	 :array, :pointer,
           :rows, :int,
           :columns, :int             
  end
  
END
    o.puts code
    o.puts
    o.puts "  # use this function to reset all cell values"
    o.puts "  attach_function 'reset', [], :void"

    worksheets do |name,xml_filename|
      o.puts
      o.puts "  # start of #{name}"  
      c_name = c_name_for_worksheet_name(name)

      # Put in place the setters, if any
      settable_refs = @cells_that_can_be_set_at_runtime[name]
      if settable_refs
        settable_refs = all_formulae[name].keys if settable_refs == :all
        settable_refs.each do |ref|
          o.puts "  attach_function 'set_#{c_name}_#{ref.downcase}', [ExcelValue.by_value], :void"
        end
      end

      if !cells_to_keep || cells_to_keep.empty? || cells_to_keep[name] == :all
        getable_refs = all_formulae[name].keys
      elsif !cells_to_keep[name] && settable_refs
        getable_refs = settable_refs
      else
        getable_refs = cells_to_keep[name] || []
      end
              
      getable_refs.each do |ref|
        o.puts "  attach_function '#{c_name}_#{ref.downcase}', [], ExcelValue.by_value"
      end
        
      o.puts "  # end of #{name}"
    end
    o.puts "end"  
    close(o)
  end
  
  def write_tests
    name = output_name.downcase
    o = output("test_#{name}.rb")    
    o.puts "# coding: utf-8"
    o.puts "# Test for #{name}"
    o.puts "require 'rubygems'"
    o.puts "gem 'minitest'"
    o.puts  "require 'test/unit'"
    o.puts  "require_relative '#{output_name.downcase}'"
    o.puts
    o.puts "class Test#{ruby_module_name} < Test::Unit::TestCase"
    o.puts "  def spreadsheet; @spreadsheet ||= init_spreadsheet; end"
    o.puts "  def init_spreadsheet; #{ruby_module_name} end"
    
    all_formulae = all_formulae()
    
    worksheets do |name,xml_filename|
      i = input([name,"Values"])
      o.puts
      o.puts "  # start of #{name}"  
      c_name = c_name_for_worksheet_name(name)
      if !cells_to_keep || cells_to_keep.empty? || cells_to_keep[name] == :all
        refs_to_test = all_formulae[name].keys
      else
        refs_to_test = cells_to_keep[name]
      end
      if refs_to_test && !refs_to_test.empty?
        refs_to_test = refs_to_test.map(&:upcase)
        CompileToCUnitTest.rewrite(i, c_name, refs_to_test, o)
      end
      close(i)
    end
    o.puts "end"
    close(o)
  end
  
  def compile_code
    return unless actually_compile_code || actually_run_tests
    puts "Compiling the resulting c code"
    puts `cd #{File.join(output_directory)}; make clean; make`
  end
  
  def run_tests
    return unless actually_run_tests
    puts "Running the resulting tests"
    puts `cd #{File.join(output_directory)}; ruby "test_#{output_name.downcase}.rb"`
  end
  
end
