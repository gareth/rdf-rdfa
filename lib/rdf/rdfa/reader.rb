require 'nokogiri'  # FIXME: Implement using different modules as in RDF::TriX

module RDF::RDFa
  ##
  # An RDFa parser in Ruby
  #
  # Based on processing rules described here:
  # @see http://www.w3.org/TR/rdfa-syntax/#s_model RDFa 1.0
  # @see http://www.w3.org/2010/02/rdfa/drafts/2010/WD-rdfa-core-20101026/ RDFa 1.1
  #
  # @author [Gregg Kellogg](http://kellogg-assoc.com/)
  class Reader < RDF::Reader
    format Format
    
    SafeCURIEorCURIEorURI = {
      :rdfa_1_0 => [:term, :safe_curie, :uri, :bnode],
      :rdfa_1_1 => [:safe_curie, :curie, :term, :uri, :bnode],
    }
    TERMorCURIEorAbsURI = {
      :rdfa_1_0 => [:term, :curie],
      :rdfa_1_1 => [:term, :curie, :absuri],
    }
    TERMorCURIEorAbsURIprop = {
      :rdfa_1_0 => [:curie],
      :rdfa_1_1 => [:term, :curie, :absuri],
    }

    NC_REGEXP = Regexp.new(
      %{^
        (?!\\\\u0301)             # &#x301; is a non-spacing acute accent.
                                  # It is legal within an XML Name, but not as the first character.
        (  [a-zA-Z_]
         | \\\\u[0-9a-fA-F]
        )
        (  [0-9a-zA-Z_\.-]
         | \\\\u([0-9a-fA-F]{4})
        )*
      $},
      Regexp::EXTENDED)
  
    # Host language
    # @return [:xhtml, :svg]
    attr_reader :host_language
    
    # Version
    # @return [:rdfa_1_0, :rdfa_1_1]
    attr_reader :version
    
    # The Recursive Baggage
    # @private
    class EvaluationContext # :nodoc:
      # The base.
      #
      # This will usually be the URL of the document being processed,
      # but it could be some other URL, set by some other mechanism,
      # such as the (X)HTML base element. The important thing is that it establishes
      # a URL against which relative paths can be resolved.
      #
      # @return [URI]
      attr :base, true
      # The parent subject.
      #
      # The initial value will be the same as the initial value of base,
      # but it will usually change during the course of processing.
      #
      # @return [URI]
      attr :parent_subject, true
      # The parent object.
      #
      # In some situations the object of a statement becomes the subject of any nested statements,
      # and this property is used to convey this value.
      # Note that this value may be a bnode, since in some situations a number of nested statements
      # are grouped together on one bnode.
      # This means that the bnode must be set in the containing statement and passed down,
      # and this property is used to convey this value.
      #
      # @return URI
      attr :parent_object, true
      # A list of current, in-scope URI mappings.
      #
      # @return [Hash{Symbol => String}]
      attr :uri_mappings, true
      # A list of current, in-scope Namespaces. This is the subset of uri_mappings
      # which are defined using xmlns.
      #
      # @return [Hash{String => Namespace}]
      attr :namespaces, true
      # A list of incomplete triples.
      #
      # A triple can be incomplete when no object resource
      # is provided alongside a predicate that requires a resource (i.e., @rel or @rev).
      # The triples can be completed when a resource becomes available,
      # which will be when the next subject is specified (part of the process called chaining).
      #
      # @return [Array<Array<URI, Resource>>]
      attr :incomplete_triples, true
      # The language. Note that there is no default language.
      #
      # @return [Symbol]
      attr :language, true
      # The term mappings, a list of terms and their associated URIs.
      #
      # This specification does not define an initial list.
      # Host Languages may define an initial list.
      # If a Host Language provides an initial list, it should do so via an RDFa Profile document.
      #
      # @return [Hash{Symbol => URI}]
      attr :term_mappings, true
      # The default vocabulary
      #
      # A value to use as the prefix URI when a term is used.
      # This specification does not define an initial setting for the default vocabulary.
      # Host Languages may define an initial setting.
      #
      # @return [URI]
      attr :default_vocabulary, true

      # @param [RDF::URI] base
      # @param [Hash] host_defaults
      # @option host_defaults [Hash{String => URI}] :term_mappings Hash of NCName => URI
      # @option host_defaults [Hash{String => URI}] :vocabulary Hash of prefix => URI
      def initialize(base, host_defaults)
        # Initialize the evaluation context, [5.1]
        @base = base
        @parent_subject = @base
        @parent_object = nil
        @namespaces = {}
        @incomplete_triples = []
        @language = nil
        @uri_mappings = host_defaults.fetch(:uri_mappings, {})
        @term_mappings = host_defaults.fetch(:term_mappings, {})
        @default_vocabulary = host_defaults.fetch(:vocabulary, nil)
      end

      # Copy this Evaluation Context
      #
      # @param [EvaluationContext] from
      def initialize_copy(from)
        # clone the evaluation context correctly
        @uri_mappings = from.uri_mappings.clone
        @incomplete_triples = from.incomplete_triples.clone
        @namespaces = from.namespaces.clone
      end
      
      def inspect
        v = %w(base parent_subject parent_object language default_vocabulary).map {|a| "#{a}='#{self.send(a).nil? ? '<nil>' : self.send(a)}'"}
        v << "uri_mappings[#{uri_mappings.keys.length}]"
        v << "incomplete_triples[#{incomplete_triples.length}]"
        v << "term_mappings[#{term_mappings.keys.length}]"
        v.join(",")
      end
    end

    ##
    # Initializes the RDFa reader instance.
    #
    # @param  [Nokogiri::HTML::Document, Nokogiri::XML::Document, IO, File, String] input
    #   the input stream to read
    # @param  [Hash{Symbol => Object}] options
    #   any additional options
    # @option options [Encoding] :encoding     (Encoding::UTF_8)
    #   the encoding of the input stream (Ruby 1.9+)
    # @option options [Boolean]  :validate     (false)
    #   whether to validate the parsed statements and values
    # @option options [Boolean]  :canonicalize (false)
    #   whether to canonicalize parsed literals
    # @option options [Boolean]  :intern       (true)
    #   whether to intern all parsed URIs
    # @option options [Hash]     :prefixes     (Hash.new)
    #   the prefix mappings to use (not supported by all readers)
    # @option options [#to_s]    :base_uri     (nil)
    #   the base URI to use when resolving relative URIs
    # @option options [:xhtml] :host_language (:xhtml)
    #   Host Language
    # @option options [:rdfa_1_0, :rdfa_1_1] :version (:rdfa_1_1)
    #   Parser version information
    # @option options [Graph]    :processor_graph (nil)
    #   Graph to record information, warnings and errors.
    # @option options [Repository] :profile_repository (nil)
    #   Repository to save profile graphs.
    # @option options [Array] :debug
    #   Array to place debug messages
    # @return [reader]
    # @yield  [reader] `self`
    # @yieldparam  [RDF::Reader] reader
    # @yieldreturn [void] ignored
    # @raise [Error]:: Raises RDF::ReaderError if _validate_
    def initialize(input = $stdin, options = {}, &block)
      super do
        @debug = options[:debug]
        @base_uri = uri(options[:base_uri])

        @version = options[:version] ? options[:version].to_sym : :rdfa_1_1
        @processor_graph = options[:processor_graph]

        @doc = case input
        when Nokogiri::HTML::Document then input
        when Nokogiri::XML::Document then input
        else   Nokogiri::XML.parse(input, @base_uri.to_s)
        end
        
        @host_language = options[:host_language] || case @doc.root.name.downcase.to_sym
        when :html  then :xhtml
        when :svg   then :svg
        else             :xhtml
        end

        add_error(nil, "Empty document", RDF::RDFA.DocumentError) if (@doc.nil? || @doc.root.nil?)
        add_warning(nil, "Synax errors:\n#{@doc.errors}", RDF::RDFA.DocumentError) if !@doc.errors.empty? && validate?
        add_error("Empty document") if (@doc.nil? || @doc.root.nil?) && validate?

        block.call(self) if block_given?
      end
      self.profile_repository = options[:profile_repository] if options[:profile_repository]
    end

    # @return [RDF::Repository]
    def profile_repository
      Profile.repository
    end
    
    # @param [RDF::Repository] repo
    # @return [RDF::Repository]
    def profile_repository=(repo)
      Profile.repository = repo
    end
    
    ##
    # Iterates the given block for each RDF statement in the input.
    #
    # @yield  [statement]
    # @yieldparam [RDF::Statement] statement
    # @return [void]
    def each_statement(&block)
      @callback = block

      # Section 4.2 RDFa Host Language Conformance
      #
      # The Host Language may define a default RDFa Profile. If it does, the RDFa Profile triples that establish term or
      # URI mappings associated with that profile must not change without changing the profile URI. RDFa Processors may
      # embed, cache, or retrieve the RDFa Profile triples associated with that profile.
      @host_defaults = case @host_language
      when :xhtml
        {
          :vocabulary => nil,
          :prefix     => "xhv",
          :uri_mappings => {"xhv" => RDF::XHV.to_s}, # RDF::XHTML is wrong
          :term_mappings => %w(
            alternate appendix bookmark cite chapter contents copyright first glossary help icon index
            last license meta next p3pv1 prev role section stylesheet subsection start top up
            ).inject({}) { |hash, term| hash[term.to_sym] = RDF::XHV[term].to_s; hash },
        }
      else
        {
          :uri_mappings => {},
        }
      end
      
      # Add prefix definitions from host defaults
      @host_defaults[:uri_mappings].each_pair do |prefix, value|
        prefix(prefix, value)
      end

      add_info(@doc, "version = #{@version},  host_language = #{@host_language}")

      # parse
      parse_whole_document(@doc, @base_uri)
    end

    ##
    # Iterates the given block for each RDF triple in the input.
    #
    # @yield  [subject, predicate, object]
    # @yieldparam [RDF::Resource] subject
    # @yieldparam [RDF::URI]      predicate
    # @yieldparam [RDF::Value]    object
    # @return [void]
    def each_triple(&block)
      each_statement do |statement|
        block.call(*statement.to_triple)
      end
    end
    
    private

    # Keep track of allocated BNodes
    def bnode(value = nil)
      @bnode_cache ||= {}
      @bnode_cache[value.to_s] ||= RDF::Node.new(value)
    end
    
    # Figure out the document path, if it is a Nokogiri::XML::Element or Attribute
    def node_path(node)
      "<#{@base_uri}>" + case node
      when Nokogiri::XML::Node then node.display_path
      else node.to_s
      end
    end
    
    # Add debug event to debug array, if specified
    #
    # @param [XML Node, any] node:: XML Node or string for showing context
    # @param [String] message::
    def add_debug(node, message)
      add_processor_message(node, message, RDF::RDFA.Info)
    end

    def add_info(node, message, process_class = RDF::RDFA.Info)
      add_processor_message(node, message, process_class)
    end
    
    def add_warning(node, message, process_class = RDF::RDFA.Warning)
      add_processor_message(node, message, process_class)
    end
    
    def add_error(node, message, process_class = RDF::RDFA.Error)
      add_processor_message(node, message, process_class)
      raise RDF::ReaderError, message if validate?
    end
    
    def add_processor_message(node, message, process_class)
      puts "#{node_path(node)}: #{message}" if ::RDF::RDFa::debug?
      @debug << "#{node_path(node)}: #{message}" if @debug.is_a?(Array)
      if @processor_graph
        @processor_sequence ||= 0
        n = RDF::Node.new
        @processor_graph << RDF::Statement.new(n, RDF["type"], process_class)
        @processor_graph << RDF::Statement.new(n, RDF::DC.description, message)
        @processor_graph << RDF::Statement.new(n, RDF::DC.date, RDF::Literal::Date.new(DateTime.now))
        @processor_graph << RDF::Statement.new(n, RDF::RDFA.sequence, RDF::Literal::Integer.new(@processor_sequence += 1))
        @processor_graph << RDF::Statement.new(n, RDF::RDFA.context, @base_uri)
        nc = RDF::Node.new
        @processor_graph << RDF::Statement.new(nc, RDF["type"], RDF::PTR.XPathPointer)
        @processor_graph << RDF::Statement.new(nc, RDF::PTR.expression, node.path)
        @processor_graph << RDF::Statement.new(n, RDF::RDFA.context, nc)
      end
    end

    # add a statement, object can be literal or URI or bnode
    #
    # @param [Nokogiri::XML::Node, any] node:: XML Node or string for showing context
    # @param [URI, BNode] subject:: the subject of the statement
    # @param [URI] predicate:: the predicate of the statement
    # @param [URI, BNode, Literal] object:: the object of the statement
    # @return [Statement]:: Added statement
    # @raise [ReaderError]:: Checks parameter types and raises if they are incorrect if parsing mode is _validate_.
    def add_triple(node, subject, predicate, object)
      statement = RDF::Statement.new(subject, predicate, object)
      add_info(node, "statement: #{RDF::NTriples.serialize(statement)}")
      @callback.call(statement)
    end

  
    # Parsing an RDFa document (this is *not* the recursive method)
    def parse_whole_document(doc, base)
      # find if the document has a base element
      case @host_language
      when :xhtml
        base_el = doc.at_css("html>head>base")
        base = base_el.attribute("href").to_s.split("#").first if base_el
      end
      
      if (base)
        # Strip any fragment from base
        base = base.to_s.split("#").first
        base = uri(base)
        add_debug("", "parse_whole_doc: base='#{base}'")
      end

      # initialize the evaluation context with the appropriate base
      evaluation_context = EvaluationContext.new(base, @host_defaults)
      
      traverse(doc.root, evaluation_context)
      add_debug("", "parse_whole_doc: traversal complete'")
    end
  
    # Parse and process URI mappings, Term mappings and a default vocabulary from @profile
    #
    # Yields each mapping
    def process_profile(element, profiles)
      profiles.
        reverse.
        map {|uri| uri(uri).normalize}.
        each do |uri|
        # Don't try to open ourselves!
        if @base_uri == uri
          add_debug(element, "process_profile: skip recursive profile <#{uri}>")
          next
        end

        old_debug = RDF::RDFa.debug?
        #RDF::RDFa.debug = false
        add_info(element, "process_profile: load <#{uri}>")
        next unless profile = Profile.find(uri)
        RDF::RDFa.debug = old_debug
        # Add URI Mappings to prefixes
        profile.prefixes.each_pair do |prefix, value|
          prefix(prefix, value)
        end
        yield :uri_mappings, profile.prefixes unless profile.prefixes.empty?
        yield :term_mappings, profile.terms unless profile.terms.empty?
        yield :default_vocabulary, profile.vocabulary if profile.vocabulary
      end
    rescue Exception => e
      add_error(element, e.message, RDF::RDFA.ProfileReferenceError)
      raise # In case we're not in strict mode, we need to be sure processing stops
    end

    # Extract the XMLNS mappings from an element
    def extract_mappings(element, uri_mappings, namespaces)
      # look for xmlns
      # (note, this may be dependent on @host_language)
      # Regardless of how the mapping is declared, the value to be mapped must be converted to lower case,
      # and the URI is not processed in any way; in particular if it is a relative path it is
      # not resolved against the current base.
      element.namespace_definitions.each do |ns|
        # A Conforming RDFa Processor must ignore any definition of a mapping for the '_' prefix.
        next if ns.prefix == "_"

        # Downcase prefix for RDFa 1.1
        pfx_lc = (@version == :rdfa_1_0 || ns.prefix.nil?) ? ns.prefix : ns.prefix.to_s.downcase
        if ns.prefix
          uri_mappings[pfx_lc.to_sym] = ns.href
          namespaces[pfx_lc] ||= ns.href
          prefix(pfx_lc, ns.href)
          add_info(element, "extract_mappings: xmlns:#{ns.prefix} => <#{ns.href}>")
        else
          namespaces[""] ||= ns.href
        end
      end

      # Set mappings from @prefix
      # prefix is a whitespace separated list of prefix-name URI pairs of the form
      #   NCName ':' ' '+ xs:anyURI
      mappings = element.attributes["prefix"].to_s.split(/\s+/)
      while mappings.length > 0 do
        prefix, uri = mappings.shift.downcase, mappings.shift
        #puts "uri_mappings prefix #{prefix} <#{uri}>"
        next unless prefix.match(/:$/)
        prefix.chop!
        
        # A Conforming RDFa Processor must ignore any definition of a mapping for the '_' prefix.
        next if prefix == "_"

        uri_mappings[prefix.to_s.empty? ? nil : prefix.to_s.to_sym] = uri
        prefix(prefix, uri)
        add_info(element, "extract_mappings: prefix #{prefix} => <#{uri}>")
      end unless @version == :rdfa_1_0
    end

    # The recursive helper function
    def traverse(element, evaluation_context)
      if element.nil?
        add_error(element, "Can't parse nil element")
        return nil
      end
      
      add_debug(element, "traverse, ec: #{evaluation_context.inspect}")

      # local variables [7.5 Step 1]
      recurse = true
      skip = false
      new_subject = nil
      current_object_resource = nil
      uri_mappings = evaluation_context.uri_mappings.clone
      namespaces = evaluation_context.namespaces.clone
      incomplete_triples = []
      language = evaluation_context.language
      term_mappings = evaluation_context.term_mappings.clone
      default_vocabulary = evaluation_context.default_vocabulary

      current_object_literal = nil  # XXX Not explicit
    
      # shortcut
      attrs = element.attributes

      about = attrs['about']
      src = attrs['src']
      resource = attrs['resource']
      href = attrs['href']
      vocab = attrs['vocab']
      xml_base = element.attribute_with_ns("base", RDF::XML.to_s)
      base = xml_base.to_s if xml_base && @host_language != :xhtml
      base ||= evaluation_context.base

      # Pull out the attributes needed for the skip test.
      property = attrs['property'].to_s.strip if attrs['property']
      typeof = attrs['typeof'].to_s.strip if attrs['typeof']
      datatype = attrs['datatype'].to_s if attrs['datatype']
      content = attrs['content'].to_s if attrs['content']
      rel = attrs['rel'].to_s.strip if attrs['rel']
      rev = attrs['rev'].to_s.strip if attrs['rev']
      profiles = attrs['profile'].to_s.split(/\s/)  # In-scope profiles in order for passing to XMLLiteral

      attrs = {
        :about => about,
        :src => src,
        :resource => resource,
        :href => href,
        :vocab => vocab,
        :base => xml_base,
        :property => property,
        :typeof => typeof,
        :daetatype => datatype,
        :rel => rel,
        :rev => rev,
        :profiles => (profiles.empty? ? nil : profiles),
      }.select{|k,v| v}
      
      add_debug(element, "traverse " + attrs.map{|a| "#{a.first}: #{a.last}"}.join(", ")) unless attrs.empty?

      # Local term mappings [7.5 Steps 2]
      # Next the current element is parsed for any updates to the local term mappings and local list of URI mappings via @profile.
      # If @profile is present, its value is processed as defined in RDFa Profiles.
      unless @version == :rdfa_1_0
        begin
          process_profile(element, profiles) do |which, value|
            add_debug(element, "[Step 2] traverse, #{which}: #{value.inspect}")
            case which
            when :uri_mappings        then uri_mappings.merge!(value)
            when :term_mappings       then term_mappings.merge!(value)
            when :default_vocabulary  then default_vocabulary = value
            end
          end 
        rescue
          # Skip this element and all sub-elements
          # If any referenced RDFa Profile is not available, then the current element and its children must not place any
          # triples in the default graph .
          raise if validate?
          return
        end
      end

      # Default vocabulary [7.5 Step 3]
      # Next the current element is examined for any change to the default vocabulary via @vocab.
      # If @vocab is present and contains a value, its value updates the local default vocabulary.
      # If the value is empty, then the local default vocabulary must be reset to the Host Language defined default.
      unless vocab.nil?
        default_vocabulary = if vocab.to_s.empty?
          # Set default_vocabulary to host language default
          add_debug(element, "[Step 2] traverse, reset default_vocaulary to #{@host_defaults.fetch(:vocabulary, nil).inspect}")
          @host_defaults.fetch(:vocabulary, nil)
        else
          uri(vocab)
        end
        add_debug(element, "[Step 2] traverse, default_vocaulary: #{default_vocabulary.inspect}")
      end
      
      # Local term mappings [7.5 Steps 4]
      # Next, the current element is then examined for URI mapping s and these are added to the local list of URI mappings.
      # Note that a URI mapping will simply overwrite any current mapping in the list that has the same name
      extract_mappings(element, uri_mappings, namespaces)
    
      # Language information [7.5 Step 5]
      # From HTML5 [3.2.3.3]
      #   If both the lang attribute in no namespace and the lang attribute in the XML namespace are set
      #   on an element, user agents must use the lang attribute in the XML namespace, and the lang
      #   attribute in no namespace must be ignored for the purposes of determining the element's
      #   language.
      language = case
      when element.at_xpath("@xml:lang", "xml" => RDF::XML["uri"].to_s)
        element.at_xpath("@xml:lang", "xml" => RDF::XML["uri"].to_s).to_s
      when element.at_xpath("lang")
        element.at_xpath("lang").to_s
      else
        language
      end
      language = nil if language.to_s.empty?
      add_debug(element, "HTML5 [3.2.3.3] traverse, lang: #{language || 'nil'}") if language
    
      # rels and revs
      rels = process_uris(element, rel, evaluation_context, base,
                          :uri_mappings => uri_mappings,
                          :term_mappings => term_mappings,
                          :vocab => default_vocabulary,
                          :restrictions => TERMorCURIEorAbsURI[@version])
      revs = process_uris(element, rev, evaluation_context, base,
                          :uri_mappings => uri_mappings,
                          :term_mappings => term_mappings,
                          :vocab => default_vocabulary,
                          :restrictions => TERMorCURIEorAbsURI[@version])
    
      add_debug(element, "traverse, rels: #{rels.join(" ")}, revs: #{revs.join(" ")}") unless (rels + revs).empty?

      if !(rel || rev)
        # Establishing a new subject if no rel/rev [7.5 Step 6]
        # May not be valid, but can exist
        new_subject = if about
          process_uri(element, about, evaluation_context, base,
                      :uri_mappings => uri_mappings,
                      :restrictions => SafeCURIEorCURIEorURI[@version])
        elsif src
          process_uri(element, src, evaluation_context, base, :restrictions => [:uri])
        elsif resource
          process_uri(element, resource, evaluation_context, base,
                      :uri_mappings => uri_mappings,
                      :restrictions => SafeCURIEorCURIEorURI[@version])
        elsif href
          process_uri(element, href, evaluation_context, base, :restrictions => [:uri])
        end

        # If no URI is provided by a resource attribute, then the first match from the following rules
        # will apply:
        #   if @typeof is present, then new subject is set to be a newly created bnode.
        # otherwise,
        #   if parent object is present, new subject is set to the value of parent object.
        # Additionally, if @property is not present then the skip element flag is set to 'true';
        new_subject ||= if @host_language == :xhtml && element.name =~ /^(head|body)$/ && base
          # From XHTML+RDFa 1.1:
          # if no URI is provided, then first check to see if the element is the head or body element.
          # If it is, then act as if there is an empty @about present, and process it according to the rule for @about.
          uri(base)
        elsif @host_language != :xhtml && base
          # XXX Spec confusion, assume that this is true
          uri(base)
        elsif element.attributes['typeof']
          RDF::Node.new
        else
          # if it's null, it's null and nothing changes
          skip = true unless property
          evaluation_context.parent_object
        end
        add_debug(element, "[Step 6] new_subject: #{new_subject}, skip = #{skip}")
      else
        # [7.5 Step 7]
        # If the current element does contain a @rel or @rev attribute, then the next step is to
        # establish both a value for new subject and a value for current object resource:
        new_subject = process_uri(element, about, evaluation_context, base,
                                  :uri_mappings => uri_mappings,
                                  :restrictions => SafeCURIEorCURIEorURI[@version]) ||
                      process_uri(element, src, evaluation_context, base,
                                  :uri_mappings => uri_mappings,
                                  :restrictions => [:uri])
      
        # If no URI is provided then the first match from the following rules will apply
        new_subject ||= if @host_language == :xhtml && element.name =~ /^(head|body)$/
          # From XHTML+RDFa 1.1:
          # if no URI is provided, then first check to see if the element is the head or body element.
          # If it is, then act as if there is an empty @about present, and process it according to the rule for @about.
          uri(base)
        elsif element.attributes['typeof']
          RDF::Node.new
        else
          # if it's null, it's null and nothing changes
          evaluation_context.parent_object
          # no skip flag set this time
        end
      
        # Then the current object resource is set to the URI obtained from the first match from the following rules:
        current_object_resource = if resource
          process_uri(element, resource, evaluation_context, base,
                      :uri_mappings => uri_mappings,
                      :restrictions => SafeCURIEorCURIEorURI[@version])
        elsif href
          process_uri(element, href, evaluation_context, base,
                      :restrictions => [:uri])
        end

        add_debug(element, "[Step 7] new_subject: #{new_subject}, current_object_resource = #{current_object_resource.nil? ? 'nil' : current_object_resource}")
      end
    
      # Process @typeof if there is a subject [Step 8]
      if new_subject and typeof
        # Typeof is TERMorCURIEorAbsURIs
        types = process_uris(element, typeof, evaluation_context, base,
                            :uri_mappings => uri_mappings,
                            :term_mappings => term_mappings,
                            :vocab => default_vocabulary,
                            :restrictions => TERMorCURIEorAbsURI[@version])
        add_debug(element, "typeof: #{typeof}")
        types.each do |one_type|
          add_triple(element, new_subject, RDF["type"], one_type)
        end
      end
    
      # Generate triples with given object [Step 9]
      if current_object_resource
        rels.each do |r|
          add_triple(element, new_subject, r, current_object_resource)
        end
      
        revs.each do |r|
          add_triple(element, current_object_resource, r, new_subject)
        end
      elsif rel || rev
        # Incomplete triples and bnode creation [Step 10]
        add_debug(element, "[Step 10] incompletes: rels: #{rels}, revs: #{revs}")
        current_object_resource = RDF::Node.new
      
        rels.each do |r|
          incomplete_triples << {:predicate => r, :direction => :forward}
        end
      
        revs.each do |r|
          incomplete_triples << {:predicate => r, :direction => :reverse}
        end
      end
    
      # Establish current object literal [Step 11]
      if property
        properties = process_uris(element, property, evaluation_context, base,
                                  :uri_mappings => uri_mappings,
                                  :term_mappings => term_mappings,
                                  :vocab => default_vocabulary,
                                  :restrictions => TERMorCURIEorAbsURIprop[@version])

        properties.reject! do |p|
          if p.is_a?(RDF::URI)
            false
          else
            add_debug(element, "predicate #{p.inspect} must be a URI")
            true
          end
        end

        # get the literal datatype
        children_node_types = element.children.collect{|c| c.class}.uniq
      
        # the following 3 IF clauses should be mutually exclusive. Written as is to prevent extensive indentation.
        datatype = process_uri(element, datatype, evaluation_context, base,
                              :uri_mappings => uri_mappings,
                              :term_mappings => term_mappings,
                              :vocab => default_vocabulary,
                              :restrictions => TERMorCURIEorAbsURI[@version]) unless datatype.to_s.empty?
        begin
          current_object_literal = if !datatype.to_s.empty? && datatype.to_s != RDF.XMLLiteral.to_s
            # typed literal
            add_debug(element, "[Step 11] typed literal (#{datatype})")
            RDF::Literal.new(content || element.inner_text.to_s, :datatype => datatype, :language => language, :validate => validate?, :canonicalize => canonicalize?)
          elsif @version == :rdfa_1_1
            if datatype.to_s == RDF.XMLLiteral.to_s
              # XML Literal
              add_debug(element, "[Step 11(1.1)] XML Literal: #{element.inner_html}")

              # In order to maintain maximum portability of this literal, any children of the current node that are
              # elements must have the current in scope XML namespace declarations (if any) declared on the
              # serialized element using their respective attributes. Since the child element node could also
              # declare new XML namespaces, the RDFa Processor must be careful to merge these together when
              # generating the serialized element definition. For avoidance of doubt, any re-declarations on the
              # child node must take precedence over declarations that were active on the current node.
              begin
                RDF::Literal.new(element.inner_html,
                                :datatype => RDF.XMLLiteral,
                                :language => language,
                                :namespaces => namespaces,
                                :validate => validate?,
                                :canonicalize => canonicalize?)
              rescue ArgumentError => e
                add_error(element, e.message)
              end
            else
              # plain literal
              add_debug(element, "[Step 11(1.1)] plain literal")
              RDF::Literal.new(content || element.inner_text.to_s, :language => language, :validate => validate?, :canonicalize => canonicalize?)
            end
          else
            if content || (children_node_types == [Nokogiri::XML::Text]) || (element.children.length == 0) || datatype == ""
              # plain literal
              add_debug(element, "[Step 11 (1.0)] plain literal")
              RDF::Literal.new(content || element.inner_text.to_s, :language => language, :validate => validate?, :canonicalize => canonicalize?)
            elsif children_node_types != [Nokogiri::XML::Text] and (datatype == nil or datatype.to_s == RDF.XMLLiteral.to_s)
              # XML Literal
              add_debug(element, "[Step 11 (1.0)] XML Literal: #{element.inner_html}")
              recurse = false
              RDF::Literal.new(element.inner_html,
                               :datatype => RDF.XMLLiteral,
                               :language => language,
                               :namespaces => namespaces,
                               :validate => validate?,
                               :canonicalize => canonicalize?)
            end
          end
        rescue ArgumentError => e
          add_error(element, e.message)
        end

      # add each property
        properties.each do |p|
          add_triple(element, new_subject, p, current_object_literal)
        end
      end
    
      if not skip and new_subject && !evaluation_context.incomplete_triples.empty?
        # Complete the incomplete triples from the evaluation context [Step 12]
        add_debug(element, "[Step 12] complete incomplete triples: new_subject=#{new_subject}, completes=#{evaluation_context.incomplete_triples.inspect}")
        evaluation_context.incomplete_triples.each do |trip|
          if trip[:direction] == :forward
            add_triple(element, evaluation_context.parent_subject, trip[:predicate], new_subject)
          elsif trip[:direction] == :reverse
            add_triple(element, new_subject, trip[:predicate], evaluation_context.parent_subject)
          end
        end
      end

      # Create a new evaluation context and proceed recursively [Step 13]
      if recurse
        if skip
          if language == evaluation_context.language &&
              uri_mappings == evaluation_context.uri_mappings &&
              term_mappings == evaluation_context.term_mappings &&
              default_vocabulary == evaluation_context.default_vocabulary &&
              base == evaluation_context.base
            new_ec = evaluation_context
            add_debug(element, "[Step 13] skip: reused ec")
          else
            new_ec = evaluation_context.clone
            new_ec.base = base
            new_ec.language = language
            new_ec.uri_mappings = uri_mappings
            new_ec.namespaces = namespaces
            new_ec.term_mappings = term_mappings
            new_ec.default_vocabulary = default_vocabulary
            add_debug(element, "[Step 13] skip: cloned ec")
          end
        else
          # create a new evaluation context
          new_ec = EvaluationContext.new(base, @host_defaults)
          new_ec.parent_subject = new_subject || evaluation_context.parent_subject
          new_ec.parent_object = current_object_resource || new_subject || evaluation_context.parent_subject
          new_ec.uri_mappings = uri_mappings
          new_ec.namespaces = namespaces
          new_ec.incomplete_triples = incomplete_triples
          new_ec.language = language
          new_ec.term_mappings = term_mappings
          new_ec.default_vocabulary = default_vocabulary
          add_debug(element, "[Step 13] new ec")
        end
      
        element.children.each do |child|
          # recurse only if it's an element
          traverse(child, new_ec) if child.class == Nokogiri::XML::Element
        end
      end
    end

    # space-separated TERMorCURIEorAbsURI or SafeCURIEorCURIEorURI
    def process_uris(element, value, evaluation_context, base, options)
      return [] if value.to_s.empty?
      add_debug(element, "process_uris: #{value}")
      value.to_s.split(/\s+/).map {|v| process_uri(element, v, evaluation_context, base, options)}.compact
    end

    def process_uri(element, value, evaluation_context, base, options = {})
      return if value.nil?
      restrictions = options[:restrictions]
      add_debug(element, "process_uri: #{value}, restrictions = #{restrictions.inspect}")
      options = {:uri_mappings => {}}.merge(options)
      if !options[:term_mappings] && options[:uri_mappings] && value.to_s.match(/^\[(.*)\]$/) && restrictions.include?(:safe_curie)
        # SafeCURIEorCURIEorURI
        # When the value is surrounded by square brackets, then the content within the brackets is
        # evaluated as a CURIE according to the CURIE Syntax definition. If it is not a valid CURIE, the
        # value must be ignored.
        uri = curie_to_resource_or_bnode(element, $1, options[:uri_mappings], evaluation_context.parent_subject, restrictions)
        add_debug(element, "process_uri: #{value} => safeCURIE => <#{uri}>")
        uri
      elsif options[:term_mappings] && NC_REGEXP.match(value.to_s) && restrictions.include?(:term)
        # TERMorCURIEorAbsURI
        # If the value is an NCName, then it is evaluated as a term according to General Use of Terms in
        # Attributes. Note that this step may mean that the value is to be ignored.
        uri = process_term(element, value.to_s, options)
        add_debug(element, "process_uri: #{value} => term => <#{uri}>")
        uri
      else
        # SafeCURIEorCURIEorURI or TERMorCURIEorAbsURI
        # Otherwise, the value is evaluated as a CURIE.
        # If it is a valid CURIE, the resulting URI is used; otherwise, the value will be processed as a URI.
        uri = curie_to_resource_or_bnode(element, value, options[:uri_mappings], evaluation_context.parent_subject, restrictions)
        if uri
          add_debug(element, "process_uri: #{value} => CURIE => <#{uri}>")
        elsif @version == :rdfa_1_0 && value.to_s.match(/^xml/i)
          # Special case to not allow anything starting with XML to be treated as a URI
        elsif restrictions.include?(:absuri) || restrictions.include?(:uri)
          begin
            # AbsURI does not use xml:base
            if restrictions.include?(:absuri)
              uri = uri(value)
              unless uri.absolute?
                uri = nil
                raise RDF::ReaderError, "Relative URI #{value}" 
              end
            else
              uri = uri(base, Addressable::URI.parse(value))
            end
          rescue Addressable::URI::InvalidURIError => e
            add_warning(element, "Malformed prefix #{value}", RDF::RDFA.UnresolvedCURIE)
          rescue RDF::ReaderError => e
            add_debug(element, e.message)
            if value.to_s =~ /^\(^\w\):/
              add_warning(element, "Undefined prefix #{$1}", RDF::RDFA.UnresolvedCURIE)
            else
              add_warning(element, "Relative URI #{value}")
            end
          end
          add_debug(element, "process_uri: #{value} => URI => <#{uri}>")
        end
        uri
      end
    end
    
    # [7.4.3] General Use of Terms in Attributes
    #
    # @param [String] term:: term
    # @param [Hash] options:: Parser options, one of
    # <em>options[:term_mappings]</em>:: Term mappings
    # <em>options[:vocab]</em>:: Default vocabulary
    def process_term(element, value, options)
      if options[:term_mappings].is_a?(Hash)
        # If the term is in the local term mappings, use the associated URI (case sensitive).
        return uri(options[:term_mappings][value.to_s.to_sym]) if options[:term_mappings].has_key?(value.to_s.to_sym)
        
        # Otherwise, check for case-insensitive match
        options[:term_mappings].each_pair do |term, uri|
          return uri(uri) if term.to_s.downcase == value.to_s.downcase
        end
      end
      
      if options[:vocab]
        # Otherwise, if there is a local default vocabulary the URI is obtained by concatenating that value and the term.
        uri(options[:vocab] + value)
      else
        # Finally, if there is no local default vocabulary, the term has no associated URI and must be ignored.
        add_warning(element, "Term #{value} is not defined", RDF::RDFA.UnresolvedTerm)
        nil
      end
    end

    # From section 6. CURIE Syntax Definition
    def curie_to_resource_or_bnode(element, curie, uri_mappings, subject, restrictions)
      # URI mappings for CURIEs default to XHV, rather than the default doc namespace
      prefix, reference = curie.to_s.split(":")

      # consider the bnode situation
      if prefix == "_" && restrictions.include?(:bnode)
        # we force a non-nil name, otherwise it generates a new name
        # As a special case, _: is also a valid reference for one specific bnode.
        bnode(reference)
      elsif curie.to_s.match(/^:/)
        add_debug(element, "curie_to_resource_or_bnode: default prefix: defined? #{!!uri_mappings[""]}, defaults: #{@host_defaults[:prefix]}")
        # Default prefix
        if uri_mappings[nil]
          uri(uri_mappings[nil] + reference.to_s)
        elsif @host_defaults[:prefix]
          uri(uri_mappings[@host_defaults[:prefix]] + reference.to_s)
        else
          #add_warning(element, "Default namespace prefix is not defined", RDF::RDFA.UnresolvedCURIE)
          nil
        end
      elsif !curie.to_s.match(/:/)
        # No prefix, undefined (in this context, it is evaluated as a term elsewhere)
        nil
      else
        # Prefixes always downcased
        prefix = prefix.to_s.downcase unless @version == :rdfa_1_0
        add_debug(element, "curie_to_resource_or_bnode check for #{prefix.to_s.to_sym.inspect} in #{uri_mappings.inspect}")
        ns = uri_mappings[prefix.to_s.to_sym]
        if ns
          uri(ns + reference.to_s)
        else
          add_debug(element, "curie_to_resource_or_bnode No namespace mapping for #{prefix}")
          nil
        end
      end
    end

    def uri(value, append = nil)
      value = RDF::URI.new(value)
      value = value.join(append) if append
      value.validate! if validate?
      value.canonicalize! if canonicalize?
      value = RDF::URI.intern(value) if intern?
      value
    end
  end
end