# EARL reporting
require 'rdf/rdfa'
require 'rdf/turtle'
require 'json/ld'
require 'sparql'
require 'haml'

##
# EARL reporting class.
# Instantiate a new class using one or more input graphs
require 'rdf/rdfa'
require 'rdf/turtle'

class EARL
  attr_reader :graph
  PROCESSOR_QUERY = %(
    PREFIX doap: <http://usefulinc.com/ns/doap#>
    PREFIX rdfatest: <http://rdfa.info/vocabs/rdfa-test#>
    
    SELECT ?uri ?name ?creator ?homepage ?doap_desc ?language
    WHERE {
      [rdfatest:processor ?uri] .
      ?uri doap:name ?name .
      OPTIONAL { ?uri dc:creator ?creator . }
      OPTIONAL { ?uri doap:homepage ?homepage . }
      OPTIONAL { ?uri doap:description ?doap_desc . }
      OPTIONAL { ?uri doap:programming-language ?language . }
    }
  ).freeze
  
  RESULT_QUERY = %(
    PREFIX earl: <http://www.w3.org/ns/earl#>
    
    SELECT ?uri ?outcome
    WHERE {
      ?uri a earl:Assertion;
        earl:result [earl:outcome ?outcome] .
    }
  ).freeze
  
  SUITE_URI = "http://rdfa.info/test-suite/"
  PROCESSORS_PATH = File.expand_path("../../processors.json", __FILE__)

  # Convenience vocabularies
  class EARL < RDF::Vocabulary("http://www.w3.org/ns/earl#"); end
  class RDFATEST < RDF::Vocabulary("http://rdfa.info/vocabs/rdfa-test#"); end

  ##
  # @param [Array<String>] files
  def initialize(files)
    @graph = RDF::Graph.new
    @prefixes = {}
    [files].flatten.each do |file|
      reader = case file
      when /\.ttl/ then RDF::Turtle::Reader
      when /\.html/ then RDF::RDFa::Reader
      end
      reader.open(file) {|r| @graph << r}
    end
    
    # Load DOAP definitions
    processors = ::JSON.parse(File.read(PROCESSORS_PATH))
    processors.each do |proc, info|
      doap_url = info["doap_url"] || info["doap"]
      next unless doap_url
      puts "read doap description for #{proc} from #{doap_url}"
      begin
        doap_graph = RDF::Graph.load(doap_url)
        @graph << doap_graph.query(:subject => RDF::URI(info["doap"])).to_a
      rescue
        # Ignore failure
      end
    end
  end

  ##
  # Dump the collesced output graph
  #
  # If there is a DOAP file associated with a processor, load it's information into the
  # graph.
  #
  # If no `io` parameter is provided, the output is returned as a string
  #
  # @param [Symbol] format
  # @param [IO] io (nil)
  # @return [String] serialized graph, if `io` is nil
  def dump(format, io = nil)
    options = {
      :base => SUITE_URI,
      :prefixes => {
        :dc => "http://purl.org/dc/terms/",
        :doap => "http://usefulinc.com/ns/doap#",
        :earl => "http://www.w3.org/ns/earl#",
      }
    }

    if format == :jsonld
      # Customized JSON-LD output
      hash = Hash.ordered
      hash["@context"] = "http://rdfa.info/contexts/rdfa-earl.jsonld"
      hash["@id"] = SUITE_URI
      hash["@type"] = %w(earl:Software doap:Project)
      hash[:homepage] = "http://rdfa.info/"
      hash[:name] = "RDFa Test Suite"
      hash[:processor] = []
      
      # Get the set of processors
      proc_info = {}
      SPARQL.execute(PROCESSOR_QUERY, @graph).each do |solution|
        info = proc_info[solution[:uri].to_s] ||= {}
        %w(name creator homepage doap_desc language).each do |prop|
          info[prop] = solution[prop.to_sym].to_s if solution[prop.to_sym]
        end
      end
      
      proc_info.each do |id, info|
        processor = Hash.ordered
        processor["@id"] = id
        processor["@type"] = %w(earl:TestSubject doap:Project)
        %w(name creator doap_desc homepage language).each do |prop|
          processor[prop] = info[prop] if info[prop]
        end
        hash[:processor] << processor
      end
      
      # Collect results
      results = {}
      SPARQL.execute(RESULT_QUERY, @graph).each do |solution|
        results[solution[:uri]] = solution[:outcome] == EARL.pass
      end

      # Get versions and hostLanguages
      @graph.query(:subject => RDF::URI(SUITE_URI)).each do |version_stmt|
        if version_stmt.predicate.to_s.index(RDFATEST["version/"]) == 0
          # This is a version predicate, it includes hostLanguage predicates
          vers = version_stmt.predicate.to_s.sub(RDFATEST["version/"].to_s, '')
          version = hash[vers] ||= begin
            vh = Hash.ordered
            vh['@type'] = "rdfatest:Version"
            puts "version: #{vers}"
            vh
          end
          
          @graph.query(:subject => version_stmt.object).each do |hl_stmt|
            if hl_stmt.predicate.to_s.index(RDFATEST["hostLanguage/"]) == 0
              # This is a hostLanguage predicate, it includes hostLanguage predicates
              hl = hl_stmt.predicate.to_s.sub(RDFATEST["hostLanguage/"].to_s, '')
              puts "hostLanguage: #{hl}"
              version[hl] = []
              
              # Iterate though the list and append ordered test assertion
              RDF::List.new(hl_stmt.object, @graph).each do |tc|
                tc_hash = Hash.ordered
                tc_hash['@id'] = tc.to_s
                tc_hash['@type'] = "earl:TestCase"
                
                # Extract important properties
                title = description = nil
                assertions = {}
                @graph.query(:subject => tc).each do |tc_stmt|
                  case tc_stmt.predicate.to_s
                  when RDF::DC.title.to_s
                    title = tc_stmt.object.to_s
                  when RDF::DC.description.to_s
                    description = tc_stmt.object.to_s
                  when EARL.mode.to_s, RDF.type.to_s
                    # Skip this
                  else
                    # Otherwise, if the object is an object, it references an Assertion
                    # with the predicate being the processorURL
                    assertions[tc_stmt.predicate.to_s] = tc_stmt.object if tc_stmt.object.uri?
                  end
                end

                tc_hash[:num] = tc.to_s.split('/').last.split('.').first
                tc_hash[:title] = title
                tc_hash[:description] = description unless description.empty?
                tc_hash[:mode] = "earl:automatic"
                
                assertions.keys.sort.each do |processor|
                  uri = assertions[processor]
                  result_hash = Hash.ordered
                  result_hash['@type'] = 'earl:TestResult'
                  result_hash[:outcome] = results[uri] ? 'earl:pass' : 'earl:fail'
                  ta_hash = Hash.ordered
                  ta_hash['@id'] = uri.to_s
                  ta_hash['@type'] = 'earl:Assertion'
                  ta_hash[:assertedBy] = SUITE_URI
                  ta_hash[:test] = tc.to_s
                  ta_hash[:subject] = processor
                  ta_hash[:result] = result_hash
                  tc_hash[processor] = ta_hash
                end

                version[hl] << tc_hash
              end
            end
          end
        end
      end

      json = hash.to_json(::JSON::State.new(
        :indent       => "  ",
        :space        => " ",
        :space_before => "",
        :object_nl    => "\n",
        :array_nl     => "\n"
      ))
      io.write(json) if io
      json
    else
      if io
        RDF::Writer.for(format).dump(@graph, io, options)
      else
        @graph.dump(format, options)
      end
    end
  end

  ##
  # Generate output report, using Haml template
  # If no `io` parameter is provided, the output is returned as a string
  #
  # @param [IO, String, Hash] json
  # @param [Array<String>] source_files
  # @param [IO] io (nil)
  # @return [String] Generated report, if `io` is nil
  def self.generate(json, source_files, io = nil)
    json = json.read if json.respond_to?(:read)
    tests = json.is_a?(String) ? ::JSON.parse(json) : json

    template = File.read(File.expand_path('../views/earl_report.html.haml', __FILE__))

    html = Haml::Engine.new(template, :format => :xhtml).render(self, {:tests => tests, :source_files => source_files})
    io.write(html) if io
    html
  end
end