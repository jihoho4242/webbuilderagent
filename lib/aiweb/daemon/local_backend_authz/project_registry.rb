# frozen_string_literal: true

module Aiweb
  module LocalBackendAuthz
    private

    def normalize_authz_project_entries(value)
      raw = normalize_authz_project_raw(value)
      entries = case raw
                when Hash
                  if raw.key?("tenants")
                    authz_tenant_registry_entries(raw)
                  elsif raw.key?("projects")
                    Array(raw.fetch("projects"))
                  else
                    raw.map do |project_id, project_value|
                      project_value.is_a?(Hash) ? project_value.merge("project_id" => project_id) : { "project_id" => project_id, "root" => project_value }
                    end
                  end
                when Array
                  raw
                else
                  []
                end

      entries.each_with_object([]) do |entry, memo|
        next unless entry.is_a?(Hash)

        root = entry["root"] || entry["path"] || entry["project_root"]
        project_id = entry["project_id"] || entry["id"]
        tenant_id = entry["tenant_id"] || authz_tenant_id
        user_ids = authz_entry_user_ids(entry)
        roles_by_user = authz_entry_roles_by_user(entry, user_ids)
        next if root.to_s.strip.empty? || project_id.to_s.strip.empty?

        memo << {
          root: File.expand_path(root.to_s),
          project_id: project_id.to_s.strip,
          tenant_id: tenant_id.to_s.strip,
          user_ids: user_ids,
          roles_by_user: roles_by_user
        }
      end
    end

    def authz_project_file_raw
      return [] if authz_projects_file.empty?

      if unsafe_env_path?(authz_projects_file)
        authz_project_registry_errors << "#{self.class::AUTHZ_PROJECTS_FILE_ENV} must not point at .env/.env.*"
        return []
      end

      path = File.expand_path(authz_projects_file)
      unless File.file?(path)
        authz_project_registry_errors << "#{self.class::AUTHZ_PROJECTS_FILE_ENV} does not exist"
        return []
      end

      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      authz_project_registry_errors << "#{self.class::AUTHZ_PROJECTS_FILE_ENV} JSON parse failed: #{e.message}"
      []
    rescue SystemCallError => e
      authz_project_registry_errors << "#{self.class::AUTHZ_PROJECTS_FILE_ENV} read failed: #{e.class}"
      []
    end

    def authz_tenant_registry_entries(raw)
      Array(raw["tenants"]).flat_map do |tenant|
        next [] unless tenant.is_a?(Hash)

        tenant_id = (tenant["tenant_id"] || tenant["id"]).to_s.strip
        tenant_roles = authz_registry_member_roles(tenant["members"] || tenant["users"])
        Array(tenant["projects"]).filter_map do |project|
          next unless project.is_a?(Hash)

          project_roles = tenant_roles.merge(authz_registry_member_roles(project["members"] || project["users"])) do |_user_id, tenant_user_roles, project_user_roles|
            (Array(tenant_user_roles) + Array(project_user_roles)).uniq
          end
          explicit_user_ids = Array(project["user_ids"] || project["allowed_user_ids"]).flat_map { |item| item.to_s.split(",") }.map(&:strip).reject(&:empty?)
          explicit_user_ids.each do |user_id|
            project_roles[user_id] ||= normalize_authz_roles_config(project["roles"] || project["role"], default: ["viewer"], context: "authz project #{project["project_id"] || project["id"] || "unknown"} user #{user_id} roles")
          end
          user_ids = project_roles.keys
          project.merge(
            "tenant_id" => tenant_id,
            "user_ids" => user_ids,
            "user_roles" => project_roles
          )
        end
      end
    end

    def authz_registry_member_roles(value)
      case value
      when Hash
        value.each_with_object({}) do |(user_id, roles), memo|
          normalized_user = user_id.to_s.strip
          next if normalized_user.empty?

          normalized_roles = normalize_authz_roles_config(roles, default: ["viewer"], context: "authz project registry member #{normalized_user}")
          memo[normalized_user] = normalized_roles
        end
      else
        Array(value).each_with_object({}) do |member, memo|
          next unless member.is_a?(Hash)

          user_id = (member["user_id"] || member["id"] || member["sub"]).to_s.strip
          next if user_id.empty?

          roles = normalize_authz_roles_config(member["roles"] || member["role"], default: ["viewer"], context: "authz project registry member #{user_id}")
          memo[user_id] = roles
        end
      end
    end

    def normalize_authz_project_raw(value)
      return [] if value.nil?
      return value unless value.is_a?(String)

      text = value.strip
      return [] if text.empty?

      JSON.parse(text)
    rescue JSON::ParserError
      []
    end

    def authz_entry_user_ids(entry)
      ids = []
      ids.concat(authz_split_user_ids(entry["user_ids"] || entry["allowed_user_ids"] || entry["user_id"]))
      ids.concat(authz_split_user_ids(entry["users"])) unless authz_member_collection?(entry["users"])
      ids.concat(authz_entry_member_roles(entry).keys)
      ids << authz_user_id if ids.empty? && !authz_user_id.empty?
      ids.map(&:strip).reject(&:empty?).uniq
    end

    def authz_entry_roles_by_user(entry, user_ids)
      raw_map = entry["user_roles"] || entry["roles_by_user"] || entry["role_map"]
      member_roles = authz_entry_member_roles(entry)
      default_roles = normalize_authz_roles_config(entry["roles"] || entry["role"], default: ["viewer"], context: "authz project #{entry["project_id"] || entry["id"] || "unknown"} default roles")
      user_ids.each_with_object({}) do |user_id, memo|
        configured = raw_map.is_a?(Hash) ? raw_map[user_id] || raw_map[user_id.to_s] : nil
        roles = if configured
                  normalize_authz_roles_config(configured, default: [], context: "authz project #{entry["project_id"] || entry["id"] || "unknown"} user #{user_id} roles")
                elsif member_roles[user_id.to_s]
                  member_roles[user_id.to_s]
                else
                  default_roles
                end
        memo[user_id.to_s] = roles
      end
    end

    def authz_entry_member_roles(entry)
      authz_registry_member_roles(entry["members"]).merge(authz_registry_member_roles(entry["users"])) do |_user_id, left_roles, right_roles|
        (Array(left_roles) + Array(right_roles)).uniq
      end
    end

    def authz_member_collection?(value)
      value.is_a?(Hash) || Array(value).any? { |item| item.is_a?(Hash) }
    end

    def authz_split_user_ids(value)
      Array(value).flat_map { |item| item.to_s.split(",") }.map(&:strip).reject(&:empty?)
    end

    def normalize_authz_roles_config(value, default:, context:)
      raw = Array(value).flat_map { |item| item.to_s.split(",") }.map(&:strip).reject(&:empty?)
      return Array(default) if raw.empty?

      normalized = raw.map(&:downcase)
      invalid = normalized.reject { |role| self.class::AUTHZ_ROLE_LEVELS.key?(role) }.uniq
      unless invalid.empty?
        authz_project_registry_errors << "#{context} contains invalid role(s): #{invalid.join(", ")}"
        return []
      end

      normalized.uniq
    end

    def normalize_authz_roles(value)
      Array(value).flat_map { |item| item.to_s.split(",") }.map(&:strip).reject(&:empty?).map(&:downcase).select { |role| self.class::AUTHZ_ROLE_LEVELS.key?(role) }.uniq
    end
  end
end
