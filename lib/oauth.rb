require 'sinatra/base'

module Sinatra
  module OAuth
    # LTI tool launch, makes sure we're oauth-good and then redirects to the magic page
    post "/badge_check" do
      key = params['oauth_consumer_key']
      tool_config = ExternalConfig.first(:config_type => 'lti', :value => key)
      secret = tool_config.shared_secret
      provider = IMS::LTI::ToolProvider.new(key, secret, params)
      if !params['custom_canvas_user_id'] || !params['custom_canvas_course_id']
        return error("Course must be a Canvas course, and launched with public permission settings")
      end
      if provider.valid_request?(request)
        user_id = params['custom_canvas_user_id']
        user_config = UserConfig.first(:user_id => user_id)
        session["launch_course_id"] = params['custom_canvas_course_id']
        session["permission_for_#{params['custom_canvas_course_id']}"] = 'view'
        session['user_id'] = user_id
        session['email'] = params['lis_person_contact_email_primary']
        # check if they're a teacher or not
        session["permission_for_#{params['custom_canvas_course_id']}"] = 'edit' if provider.roles.include?('instructor') || provider.roles.include?('contentdeveloper') || provider.roles.include?('urn:lti:instrole:ims/lis/administrator') || provider.roles.include?('administrator')
        
        # if we already have an oauth token then we're good
        if user_config
          session['api_host'] = user_config.host
          redirect to("/badge_check/#{params['custom_canvas_course_id']}/#{session['user_id']}")
        # otherwise we need to do the oauth dance for this user
        else
          host = params['tool_consumer_instance_guid'].split(/\./)[1..-1].join(".")
          session['api_host'] = host
          oauth_dance(request, host)
        end
      else
        return error("Invalid tool launch")
      end
    end

    get "/oauth_success" do
      session['api_host'] ||= 'canvas.instructure.com'
      return_url = "#{protocol}://#{request.host_with_port}/oauth_success"
      code = params['code']
      url = "#{protocol}://#{session['api_host']}/login/oauth2/token"
      uri = URI.parse(url)
      
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = protocol == "https"
      request = Net::HTTP::Post.new(uri.request_uri)
      request.set_form_data({
        :client_id => oauth_config.value,
        :code => code,
        :client_secret => oauth_config.shared_secret,
        :redirect_uri => CGI.escape(return_url)
      })
      response = http.request(request)
      json = JSON.parse(response.body)
      puts "retrieving token from #{url}..."
      puts response.body
      
      if json && json['access_token']
        user_config = UserConfig.first(:user_id => session['user_id'])
        user_config ||= UserConfig.new(:user_id => session['user_id'])
        user_config.access_token = json['access_token']
        user_config.host = session['api_host']
        user_config.save
        redirect to("/badge_check/#{session['launch_course_id']}/#{session['user_id']}")
        user_id = session['user_id']
        session.destroy
        session['user_id'] = user_id
      else
        return error("Error retrieving access token")
      end
    end
  end
  
  register OAuth
end
