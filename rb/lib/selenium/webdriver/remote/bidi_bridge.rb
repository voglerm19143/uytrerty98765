# frozen_string_literal: true

# Licensed to the Software Freedom Conservancy (SFC) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The SFC licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

require 'selenium/webdriver/bidi'

module Selenium
  module WebDriver
    module Remote
      # @api private
      class BiDiBridge < Bridge
        include BiDiCommands

        attr_reader :bidi, :connection, :context_tree, :listener_errors, :alerts

        def create_session(capabilities)
          @listener_errors = ListenerErrors.new
          @alerts = Alerts.new(self, capabilities)
          super
          # The remote end reports the 'ignore' it was sent, which is not what applies
          @capabilities[:unhandled_prompt_behavior] = nil

          begin
            @bidi = Selenium::WebDriver::BiDi.new(url: validated_socket_url)
            # Reuse the BiDi object's socket as the connection until the bridge owns it directly.
            @connection = @bidi.ws
            @connection.before_send << ->(_payload) { @listener_errors.check }
            @context_tree = BiDi::ContextTree.new(@connection)
            @current_window = window_handle
            @alerts.subscribe
          rescue StandardError
            quit
            raise
          end
        end

        # A stored error is raised once the session has ended, and outside Bridge#quit's rescue of connection errors
        def quit
          bidi&.close
        rescue *QUIT_ERRORS
          nil
        ensure
          super
          @listener_errors.check
        end

        def close
          execute(:close_window).tap { |handles| bidi.close if handles.empty? }
        end

        def accept_alert(prompt = nil)
          prompt ||= @alerts.current
          # Sent explicitly: remote ends accept a prompt with empty text rather than its default
          text = prompt.keys || prompt.default_value if prompt.type == 'prompt'
          close_prompt(prompt, accept: true, text: text)
        end

        def dismiss_alert(prompt = nil)
          close_prompt(prompt || @alerts.current, accept: false)
        end

        def send_alert_text(keys, prompt = nil)
          prompt ||= @alerts.current
          raise Error::ElementNotInteractableError, "#{prompt.type} does not take text" unless prompt.type == 'prompt'

          # BiDi sends text only with the accept, so a dismissed prompt never receives it
          WebDriver.logger.debug('Keys for a prompt are sent when it is accepted', id: :alerts)
          prompt.keys = keys
        end

        def alert_text(prompt = nil)
          (prompt || @alerts.current).text
        end

        def alert_type(prompt = nil)
          (prompt || @alerts.current).type
        end

        def alert_default_value(prompt = nil)
          (prompt || @alerts.current).default_value
        end

        private

        def close_prompt(prompt, accept:, text: nil)
          bidi_browsing_context.handle_user_prompt(context: prompt.context, accept: accept,
                                                   user_text: text || BiDi::Serialization::UNSET)
          @alerts.forget(prompt)
        end

        def execute(command, *)
          @listener_errors.check unless command == :delete_session
          begin
            super
          rescue Error::WebDriverError => e
            @alerts.manage_exception(e)
            super
          end
        end

        def validated_socket_url
          url = @capabilities[:web_socket_url]
          return url if url.is_a?(String) && url.start_with?('ws://', 'wss://')

          raise Error::WebDriverError,
                "BiDi was enabled, but the remote end did not return a valid webSocketUrl: #{url.inspect}."
        end
      end # BiDiBridge
    end # Remote
  end # WebDriver
end # Selenium
