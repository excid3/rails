# frozen_string_literal: true

require "cases/helper"

class Account
  include ActiveModel::Attributes
  include ActiveModel::SchematizedJson

  attribute :settings
  has_json :settings, restricts_access: true, max_invites: 10, greeting: "Hello!", beta: :boolean

  attribute :flags
  has_delegated_json :flags, premium: false

  attribute :flags_with_defaults, default: { "staff" => false, "early_adopter" => true }
  has_json :flags_with_defaults, staff: true, early_adopter: false

  attribute :preferences
  has_json :preferences, tags: [:string], favorite_ids: [:integer], locales: ["en", "fr"], toggles: [true, false]

  attribute :mutable_defaults
  has_json :mutable_defaults, greeting: +"Hello!"
end

class SchematizedJsonTest < ActiveModel::TestCase
  setup do
    @account = Account.new
  end

  test "boolean" do
    assert @account.settings.restricts_access?

    @account.settings.restricts_access = false
    assert_not @account.settings.restricts_access?

    @account.settings.restricts_access = "true"
    assert @account.settings.restricts_access?
  end

  test "boolean without default" do
    assert_nil @account.settings.beta
    assert_not @account.settings.beta?
  end

  test "integer" do
    assert_equal 10, @account.settings.max_invites

    @account.settings.max_invites = 15
    assert_equal 15, @account.settings.max_invites

    @account.settings.max_invites = "100"
    assert_equal 100, @account.settings.max_invites
  end

  test "string" do
    assert_equal "Hello!", @account.settings.greeting
    @account.settings.greeting = 100
    assert_equal "100", @account.settings.greeting
  end

  test "delegated accessors" do
    assert_not @account.premium?
    @account.premium = true
    assert @account.premium?
  end

  test "mass assignment" do
    @account.settings = { "restricts_access" => "false", "max_invites" => "5", "greeting" => "goodbye" }
    assert_not @account.settings.restricts_access?
    assert_equal 5, @account.settings.max_invites
    assert_equal "goodbye", @account.settings.greeting
  end

  test "schema defaults will not overwrite attribute defaults" do
    assert_not @account.flags_with_defaults.staff?
    assert @account.flags_with_defaults.early_adopter?
  end

  test "defaults are not shared between records" do
    @account.mutable_defaults.greeting << "!"
    assert_equal "Hello!", Account.new.mutable_defaults.greeting
  end

  test "defaults are stored in the attribute" do
    @account.settings.max_invites
    assert_equal({ "restricts_access" => true, "max_invites" => 10, "greeting" => "Hello!", "beta" => nil }, @account.attributes["settings"])
  end

  test "mass assignment of an unknown key raises" do
    assert_raises(NoMethodError) do
      @account.settings = { "max_invites" => "5", "unknown" => "value" }
    end
  end

  test "array declared with a type defaults to empty" do
    assert_equal [], @account.preferences.tags
    assert_not @account.preferences.tags?

    @account.preferences.tags << "ruby"
    assert @account.preferences.tags?
  end

  test "array with default" do
    assert_equal ["en", "fr"], @account.preferences.locales
    assert @account.preferences.locales?
  end

  test "array elements are cast to the element type" do
    @account.preferences.favorite_ids = ["1", 2, "3"]
    assert_equal [1, 2, 3], @account.preferences.favorite_ids

    @account.preferences.toggles = ["true", "0", false]
    assert_equal [true, false, false], @account.preferences.toggles
  end

  test "array elements that are blank strings or nil are dropped" do
    @account.preferences.tags = ["", " ", "ruby", nil, "rails"]
    assert_equal ["ruby", "rails"], @account.preferences.tags

    @account.preferences.favorite_ids = ["", " ", "1"]
    assert_equal [1], @account.preferences.favorite_ids
  end

  test "array assignment wraps a single value and keeps nil" do
    @account.preferences.tags = "ruby"
    assert_equal ["ruby"], @account.preferences.tags

    @account.preferences.tags = nil
    assert_nil @account.preferences.tags
  end

  test "invalid schema types are rejected when declared" do
    invalid_schemas = [
      { creation: :datetime }, { nesting: {} }, { time: Time.now },
      { empty: [] }, { nested: [[1]] }, { mixed: [1, "a"] }, { hashes: [{}] }, { unsupported: [:datetime] }
    ]

    invalid_schemas.each do |schema|
      assert_raises(ArgumentError, "expected #{schema} to be rejected") do
        Class.new(Account) { attribute :broken; has_json :broken, **schema }
      end
    end
  end
end
