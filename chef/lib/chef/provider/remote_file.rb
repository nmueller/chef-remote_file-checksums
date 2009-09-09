#
# Author:: Adam Jacob (<adam@opscode.com>)
# Copyright:: Copyright (c) 2008 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/provider/file'
require 'chef/rest'
require 'chef/mixin/find_preferred_file'
require 'uri'
require 'tempfile'
require 'net/https'

class Chef
  class Provider
    class RemoteFile < Chef::Provider::File

      include Chef::Mixin::FindPreferredFile

      def action_create
        Chef::Log.debug("Checking #{@new_resource} for changes")
        do_remote_file(@new_resource.source, @current_resource.path)
      end

      def action_create_if_missing
        if ::File.exists?(@new_resource.path)
          Chef::Log.debug("File #{@new_resource.path} exists, taking no action.")
        else
          action_create
        end
      end

      def do_remote_file(source, path)
        retval = true

        if(@new_resource.checksum && @current_resource.checksum && @current_resource.checksum =~ /^#{@new_resource.checksum}/)
          Chef::Log.debug("File #{@new_resource} checksum matches, not updating")
        else
          begin
            # The remote filehandle
            raw_file = get_from_uri(source)    ||
                       get_from_server(source, @current_resource.checksum) ||
                       get_from_local_cookbook(source)
            @new_resource.checksum(self.checksum(raw_file.path))

            if @new_resource.checksum == @current_resource.checksum
              Chef::Log.debug("File #{@new_resouce} unchanged, not updating")
            else
              # If the file exists
              if ::File.exists?(@new_resource.path)
                # Updating target file, let's perform a backup!
                Chef::Log.debug("#{@new_resource} changed from #{@current_resource.checksum} to #{@new_resource.checksum}")
                Chef::Log.info("Updating #{@new_resource} at #{@new_resource.path}")
                backup(@new_resource.path)
              else
                # We're creating a new file
                Chef::Log.info("Creating #{@new_resource} at #{@new_resource.path}")
              end

              FileUtils.cp(raw_file.path, @new_resource.path)
              @new_resource.updated = true

              # We're done with the file, so make sure to close it if it was open.
              raw_file.close unless raw_file.closed?
            end
          rescue Net::HTTPRetriableError => e
            if e.response.kind_of?(Net::HTTPNotModified)
              Chef::Log.debug("File #{path} is unchanged")
              retval = false
            else
              raise e
            end
          end
        end
        
        set_owner if @new_resource.owner
        set_group if @new_resource.group
        set_mode  if @new_resource.mode

        retval
      end

      def get_from_uri(source)
        begin
          uri = URI.parse(source)
          if uri.absolute
            r = Chef::REST.new(source)
            Chef::Log.debug("Downloading from absolute URI: #{source}")
            r.get_rest(source, true).open
          end
        rescue URI::InvalidURIError
          nil
        end
      end

      def get_from_server(source, current_checksum)
        unless Chef::Config[:solo]
          r = Chef::REST.new(Chef::Config[:remotefile_url])
          url = generate_url(source, "files", :checksum => current_checksum)
          Chef::Log.debug("Downloading from server: #{url}")
          r.get_rest(url, true).open
        end
      end

      def get_from_local_cookbook(source)
        if Chef::Config[:solo]
          cookbook_name = @new_resource.cookbook || @new_resource.cookbook_name
          filename = find_preferred_file(
            cookbook_name,
            :remote_file,
            source,
            @node[:fqdn],
            @node[:platform],
            @node[:platform_version]
          )
          Chef::Log.debug("Using local file for remote_file:#{filename}")
          ::File.open(filename)
        end
      end

    end
  end
end
