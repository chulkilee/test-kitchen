# -*- encoding: utf-8 -*-
#
# Author:: Fletcher Nichol (<fnichol@nichol.ca>)
#
# Copyright (C) 2013, Fletcher Nichol
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'buff/ignore'
require 'fileutils'
require 'pathname'
require 'json'
require 'kitchen/util'

module Kitchen

  module Provisioner

    # Common implementation details for Chef-related provisioners.
    #
    # @author Fletcher Nichol <fnichol@nichol.ca>
    class ChefBase < Base

      def install_command
        return nil unless config[:require_chef_omnibus]

        url = config[:chef_omnibus_url] || "https://www.opscode.com/chef/install.sh"
        flag = config[:require_chef_omnibus]
        version = if flag.is_a?(String) && flag != "latest"
          "-v #{flag.downcase}"
        else
          ""
        end

        # use Bourne (/bin/sh) as Bash does not exist on all Unix flavors
        <<-INSTALL.gsub(/^ {10}/, '')
          sh -c '
          #{Util.shell_helpers}

          should_update_chef() {
            case "#{flag}" in
              true|`chef-solo -v | cut -d " " -f 2`) return 1 ;;
              latest|*) return 0 ;;
            esac
          }

          if [ ! -d "/opt/chef" ] || should_update_chef ; then
            echo "-----> Installing Chef Omnibus (#{flag})"
            do_download #{url} /tmp/install.sh
            #{sudo('sh')} /tmp/install.sh #{version}
          fi'
        INSTALL
      end

      def init_command
        dirs = %w{data_bags roles environments cookbooks data}.
          map { |dir| File.join(home_path, dir) }.join(" ")
        "#{sudo('rm')} -rf #{dirs}"
      end

      def cleanup_sandbox
        return if tmpdir.nil?

        debug("Cleaning up local sandbox in #{tmpdir}")
        FileUtils.rmtree(tmpdir)
      end

      protected

      def create_chef_sandbox
        @tmpdir = Dir.mktmpdir("#{instance.name}-sandbox-")
        File.chmod(0755, @tmpdir)
        debug("Creating local sandbox in #{tmpdir}")

        yield if block_given?
        prepare_json
        prepare_data_bags
        prepare_roles
        prepare_nodes
        prepare_environments
        prepare_secret
        prepare_cache
        prepare_cookbooks
        prepare_data
        tmpdir
      end

      def prepare_json
        File.open(File.join(tmpdir, "dna.json"), "wb") do |file|
          file.write(instance.dna.to_json)
        end
      end

      def prepare_data
        return unless data

        info("Preparing data")
        debug("Using data from #{data}")

        tmpdata_dir = File.join(tmpdir, "data")
        FileUtils.mkdir_p(tmpdata_dir)
        FileUtils.cp_r(Dir.glob("#{data}/*"), tmpdata_dir)
      end

      def prepare_data_bags
        return unless data_bags

        info("Preparing data bags")
        debug("Using data bags from #{data_bags}")

        tmpbags_dir = File.join(tmpdir, "data_bags")
        FileUtils.mkdir_p(tmpbags_dir)
        FileUtils.cp_r(Dir.glob("#{data_bags}/*"), tmpbags_dir)
      end

      def prepare_roles
        return unless roles

        info("Preparing roles")
        debug("Using roles from #{roles}")

        tmproles_dir = File.join(tmpdir, "roles")
        FileUtils.mkdir_p(tmproles_dir)
        FileUtils.cp_r(Dir.glob("#{roles}/*"), tmproles_dir)
      end

      def prepare_nodes
        return unless nodes

        info("Preparing nodes")
        debug("Using nodes from #{nodes}")

        tmpnodes_dir = File.join(tmpdir, "nodes")
        FileUtils.mkdir_p(tmpnodes_dir)
        FileUtils.cp_r(Dir.glob("#{nodes}/*"), tmpnodes_dir)
      end

      def prepare_environments
        return unless environments

        info("Preparing environments")
        debug("Using environments from #{environments}")

        tmpenvs_dir = File.join(tmpdir, "environments")
        FileUtils.mkdir_p(tmpenvs_dir)
        FileUtils.cp_r(Dir.glob("#{environments}/*"), tmpenvs_dir)
      end

      def prepare_secret
        return unless secret

        info("Preparing encrypted data bag secret")
        debug("Using secret from #{secret}")

        FileUtils.cp_r(secret, File.join(tmpdir, "encrypted_data_bag_secret"))
      end

      def prepare_cache
        FileUtils.mkdir_p(File.join(tmpdir, "cache"))
      end

      def prepare_cookbooks
        if File.exists?(berksfile)
          resolve_with_berkshelf
        elsif File.exists?(cheffile)
          resolve_with_librarian
        elsif File.directory?(cookbooks_dir)
          cp_cookbooks
        elsif File.exists?(metadata_rb)
          cp_this_cookbook
        else
          FileUtils.rmtree(tmpdir)
          fatal("Berksfile, Cheffile, cookbooks/, or metadata.rb" +
            " must exist in #{kitchen_root}")
          raise UserError, "Cookbooks could not be found"
        end

        remove_ignored_files
      end

      def remove_ignored_files
        cookbooks_in_tmpdir do |cookbook_path|
          chefignore = File.join(cookbook_path, "chefignore")
          if File.exist? chefignore
            ignores = Buff::Ignore::IgnoreFile.new(chefignore)
            cookbook_files = Dir.glob(File.join(cookbook_path, "**/*"), File::FNM_DOTMATCH).
              select { |fn| File.file?(fn) && fn != '.' && fn != '..' }
            cookbook_files.each { |file| FileUtils.rm(file) if ignores.ignored?(file) }
          end
        end
      end

      def berksfile
        File.join(kitchen_root, "Berksfile")
      end

      def cheffile
        File.join(kitchen_root, "Cheffile")
      end

      def metadata_rb
        File.join(kitchen_root, "metadata.rb")
      end

      def cookbooks_dir
        File.join(kitchen_root, "cookbooks")
      end

      def site_cookbooks_dir
        File.join(kitchen_root, "site-cookbooks")
      end

      def data_bags
        instance.suite.data_bags_path
      end

      def roles
        instance.suite.roles_path
      end

      def nodes
        instance.suite.nodes_path
      end

      def data
        instance.suite.data_path
      end

      def environments
        instance.suite.environments_path
      end

      def secret
        instance.suite.encrypted_data_bag_secret_key_path
      end

      def tmpbooks_dir
        File.join(tmpdir, "cookbooks")
      end

      def tmpsitebooks_dir
        File.join(tmpdir, "cookbooks")
      end

      def cp_cookbooks
        info("Preparing cookbooks from project directory")
        debug("Using cookbooks from #{cookbooks_dir}")

        FileUtils.mkdir_p(tmpbooks_dir)
        FileUtils.cp_r(File.join(cookbooks_dir, "."), tmpbooks_dir)

        info("Preparing site-cookbooks from project directory")
        debug("Using cookbooks from #{site_cookbooks_dir}")

        FileUtils.mkdir_p(tmpsitebooks_dir)
        FileUtils.cp_r(File.join(site_cookbooks_dir, "."), tmpsitebooks_dir)

        cp_this_cookbook if File.exists?(metadata_rb)
      end

      def cp_this_cookbook
        info("Preparing current project directory as a cookbook")
        debug("Using metadata.rb from #{metadata_rb}")

        cb_name = MetadataChopper.extract(metadata_rb).first or raise(UserError,
          "The metadata.rb does not define the 'name' key." +
            " Please add: `name '<cookbook_name>'` to metadata.rb and retry")

        cb_path = File.join(tmpbooks_dir, cb_name)

        glob = Dir.glob("#{kitchen_root}/**")

        FileUtils.mkdir_p(cb_path)
        FileUtils.cp_r(glob, cb_path)
      end

      def resolve_with_berkshelf
        info("Resolving cookbook dependencies with Berkshelf...")
        debug("Using Berksfile from #{berksfile}")

        begin
          require 'berkshelf'
        rescue LoadError => e
          fatal("The `berkshelf' gem is missing and must be installed" +
            " or cannot be properly activated. Run" +
            " `gem install berkshelf` or add the following to your" +
            " Gemfile if you are using Bundler: `gem 'berkshelf'`.")
          raise UserError,
            "Could not load or activate Berkshelf (#{e.message})"
        end

        Kitchen.mutex.synchronize do
          Berkshelf.ui.mute do
            Berkshelf::Berksfile.from_file(berksfile).
              install(:path => tmpbooks_dir)
          end
        end
      end

      def resolve_with_librarian
        info("Resolving cookbook dependencies with Librarian-Chef")
        debug("Using Cheffile from #{cheffile}")

        begin
          require 'librarian/chef/environment'
          require 'librarian/action/resolve'
          require 'librarian/action/install'
        rescue LoadError => e
          fatal("The `librarian-chef' gem is missing and must be installed" +
            " or cannot be properly activated. Run" +
            " `gem install librarian-chef` or add the following to your" +
            " Gemfile if you are using Bundler: `gem 'librarian-chef'`.")
          raise UserError,
            "Could not load or activate Librarian-Chef (#{e.message})"
        end

        Kitchen.mutex.synchronize do
          env = Librarian::Chef::Environment.new(:project_path => kitchen_root)
          env.config_db.local["path"] = tmpbooks_dir
          Librarian::Action::Resolve.new(env).run
          Librarian::Action::Install.new(env).run
        end
      end

      private

      def cookbooks_in_tmpdir
        Dir.glob(File.join(tmpbooks_dir, "*/")).each do |cookbook_path|
          yield cookbook_path if block_given?
        end
      end
    end
  end
end
