#!/usr/bin/ruby
#
# This file is part of CPEE-LLM-DOCUMENTS.
#
# CPEE-LLM-DOCUMENTS is free software: you can redistribute it and/or
# modify it under the terms of the GNU General Public License as published
# by the Free Software Foundation, either version 3 of the License, or (at
# your option) any later version.
#
# CPEE-LLM-DOCUMENTS is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
# Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with CPEE-LLM-DOCUMENTS (file LICENSE in the main directory). If not, see
# <http://www.gnu.org/licenses/>.

require 'riddl/server'
require 'riddl/client'
require 'uri'
require 'json'
require 'tmpdir'

module CPEE
  module LLM
    module Documents
      SERVER = File.expand_path(File.join(__dir__,'implementation.xml'))

      class DoDocument < Riddl::Implementation #{{{
        OFFICE_EXTENSIONS = {
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document'   => '.docx',
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'         => '.xlsx',
          'application/vnd.openxmlformats-officedocument.presentationml.presentation' => '.pptx',
          'application/msword'            => '.doc',
          'application/vnd.ms-excel'      => '.xls',
          'application/vnd.ms-powerpoint' => '.ppt'
        }.freeze

        def office_to_pdf_soffice(param)
          ext = OFFICE_EXTENSIONS[param.mimetype]
          return param unless ext
          Dir.mktmpdir do |dir|
            input   = File.join(dir, "document#{ext}")
            profile = File.join(dir, 'lo_profile')
            errlog  = File.join(dir, 'soffice.err')
            File.binwrite(input, param.value.read)

            ok = system(
              'soffice', '--headless', '--norestore',
              "-env:UserInstallation=file://#{profile}",
              '--convert-to', 'pdf', '--outdir', dir, input,
              out: File::NULL, err: errlog
            )

            output = File.join(dir, 'document.pdf')

            unless ok && File.exist?(output)
              warn "office_to_pdf: soffice conversion failed for #{input} (system() => #{ok.inspect})"
              warn File.read(errlog) if File.exist?(errlog) && !File.zero?(errlog)
              return param
            end

            return Riddl::Parameter::Complex.new('document', 'application/pdf', File.binread(output))
          end
        end
        private :office_to_pdf_soffice

        def response
          user_input    = @p.find { |p| p.name == 'user_input' }.value.read
          llm           = @p.find { |p| p.name == 'llm' }.value.read

          document_urls = user_input.scan(%r{https?://\S+}i).map { |u| u.sub(/\Ahttps:\/\//i, 'http://').sub(/[.,;:!?)\]}'"]+\z/, '') }

          documents = document_urls.map do |url|
            dstatus, dres = Riddl::Client.new(url).get
            param = dres.first
            param.name = 'document'

            office_to_pdf_soffice(param)
          end

          system_prompt = <<~PROMPT
            You are extracting information from a document that has been
            attached to this request. The document describes, or is
            relevant to, a business process.

            Focus your extraction on concepts relevant to a process model:
            - Tasks (activities/steps that are performed)
            - Gateways (decision points, splits, and joins)
            - Control flow: whether tasks are arranged in sequence (one
              after another) or in parallel (happening concurrently)
            - Any conditions, roles, or data associated with tasks and
              gateways, where present in the document

            Answer the user's request using information found in the
            attached document, expressed in terms of these process model
            concepts wherever applicable.
          PROMPT

          status, res = Riddl::Client.new(@a[0][:generic_endpoint]).post([
            Riddl::Parameter::Complex.new('llm', 'text/plain', llm),
            Riddl::Parameter::Complex.new('user_input', 'text/plain', user_input),
            Riddl::Parameter::Complex.new('system_prompt', 'text/plain', system_prompt),
            Riddl::Parameter::Complex.new('format', 'text/plain', 'false')
          ] + documents)

          raw = res.first.value
          raw = raw.read if raw.respond_to?(:read)
          result = JSON.parse(raw)

          if status < 200 || status >= 300 || result['error']
            @status = 502
            return Riddl::Parameter::Complex.new('response', 'text/plain', (result['error'] || raw).to_s)
          end

          Riddl::Parameter::Complex.new('response', 'text/plain', result['llm_response'].to_s)
        end
      end #}}}

      def self::implementation(opts)
        opts[:generic_endpoint] ||= 'http://localhost:9305/generic/'

        Proc.new do
          on resource do
            run DoDocument, opts if put 'docin'
          end
        end
      end
    end
  end
end
