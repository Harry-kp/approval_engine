class User < ApplicationRecord
  # The actor-resolution seam the engine calls when stamping an approval out of a
  # template. Returns every user in the requested group; the engine creates one
  # step per returned actor and applies the layer's consensus policy.
  def self.resolve_approval_group(group_name, _target)
    where(role: group_name).order(:id).to_a
  end
end
