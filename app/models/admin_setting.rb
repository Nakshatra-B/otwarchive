class AdminSetting < ApplicationRecord
  include AfterCommitEverywhere

  belongs_to :last_updated, class_name: 'Admin', foreign_key: :last_updated_by
  validates_presence_of :last_updated_by
  validates :invite_from_queue_number, numericality: { greater_than_or_equal_to: 1,
    allow_nil: false, message: "must be greater than 0. To <strong>disable</strong> invites, uncheck the appropriate setting." }

  before_save :update_invite_date
  before_update :check_filter_status

  belongs_to :default_skin, class_name: 'Skin'

  DEFAULT_SETTINGS = {
    invite_from_queue_enabled?: ArchiveConfig.INVITE_FROM_QUEUE_ENABLED,
    request_invite_enabled?: false,
    invite_from_queue_at: nil,
    invite_from_queue_number: ArchiveConfig.INVITE_FROM_QUEUE_NUMBER,
    invite_from_queue_frequency: ArchiveConfig.INVITE_FROM_QUEUE_FREQUENCY,
    account_creation_enabled?: ArchiveConfig.ACCOUNT_CREATION_ENABLED,
    days_to_purge_unactivated: 2,
    suspend_filter_counts?: false,
    enable_test_caching?: false,
    cache_expiration: 10,
    tag_wrangling_off?: false,
    downloads_enabled?: true,
    disable_support_form?: false,
    default_skin_id: nil
  }.freeze

  # Create AdminSetting.first on a blank database. We call this only in an initializer
  # or a testing setup, not as part of any heavily used methods (e.g. AdminSetting.current).
  def self.default
    return AdminSetting.first if AdminSetting.first

    settings = AdminSetting.new(
      invite_from_queue_enabled: ArchiveConfig.INVITE_FROM_QUEUE_ENABLED,
      invite_from_queue_number: ArchiveConfig.INVITE_FROM_QUEUE_NUMBER,
      invite_from_queue_frequency: ArchiveConfig.INVITE_FROM_QUEUE_FREQUENCY,
      account_creation_enabled: ArchiveConfig.ACCOUNT_CREATION_ENABLED,
      days_to_purge_unactivated: 2
    )
    settings.save(validate: false)
    settings
  end

  def self.current
    Rails.cache.fetch("admin_settings-v2", race_condition_ttl: 10.seconds) { AdminSetting.first } || OpenStruct.new(DEFAULT_SETTINGS)
  end

  class << self
    delegate *DEFAULT_SETTINGS.keys, :to => :current
    delegate :default_skin, to: :current
  end

  # run hourly with the resque scheduler
  def self.check_queue
    return unless self.invite_from_queue_enabled? && InviteRequest.any? && Time.current >= self.invite_from_queue_at

    new_time = Time.current + self.invite_from_queue_frequency.hours
    current_setting = self.first
    current_setting.invite_from_queue_at = new_time
    current_setting.save(validate: false, touch: false)
    InviteFromQueueJob.perform_now(count: invite_from_queue_number)
  end

  @queue = :admin
  # This will be called by a worker when a job needs to be processed
  def self.perform(method, *args)
    self.send(method, *args)
  end

  after_save :recache_settings
  def recache_settings
    # If the default skin has just been created and set, it will have a closed
    # file handle from attaching a preview image, and cannot be serialized for
    # caching. To avoid that, we need to reload a fresh copy of the record,
    # within the current transaction to guarantee up-to-date data.
    self.reload

    # However, we only cache it if the transaction is successful.
    after_commit { Rails.cache.write("admin_settings-v2", self) }
  end

  private

  def check_filter_status
    if self.suspend_filter_counts_changed?
      if self.suspend_filter_counts?
        self.suspend_filter_counts_at = Time.now
      else
        #FilterTagging.update_filter_counts_since(self.suspend_filter_counts_at)
      end
    end
  end

  def update_invite_date
    if self.invite_from_queue_frequency_changed?
      self.invite_from_queue_at = Time.current + self.invite_from_queue_frequency.hours
    end
  end
end
