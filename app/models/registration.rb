# frozen_string_literal: true

require 'barby/barcode/ean_13'
class Registration < ApplicationRecord
  belongs_to :event, optional: true
  belongs_to :access_level

  scope :paid, -> { where("price <= paid") }

  validates :name, presence: true
  # Uniqueness temporarily disabled; see the Partner model for the reason
  # validates :email, presence: true, uniqueness: { scope: :event_id }
  validates :email, presence: true, email: true
  validates :student_number, # rubocop:disable Rails/UniqueValidationWithoutIndex as partial indexes aren't supported on Sqlite
            format: { with: /\A[0-9]*\Z/, message: "has invalid format" },
            uniqueness: { scope: :event },
            allow_blank: true
  validates :student_number, presence: true, if: -> { access_level.requires_login? }
  validates :paid, presence: true, numericality: { only_integer: true }
  validates :price, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :payment_code, presence: true, uniqueness: true

  has_paper_trail only: [:paid, :payment_code, :checked_in_at]

  before_validation do |record|
    record.payment_code = Registration.create_payment_code if record.payment_code.nil?
  end

  after_save do |record|
    if !record.access_level.capacity.nil? && (record.access_level.registrations.count > record.access_level.capacity)
      record.errors.add :access_level, "type is sold out."
      raise ActiveRecord::Rollback
    end
  end

  default_scope { order "name ASC" }

  def paid
    from_cents read_attribute(:paid)
  end

  def paid=(value)
    write_attribute :paid, to_cents(value)
  end

  def to_pay
    self.price - self.paid
  end

  def to_pay=(value)
    self.paid = self.price - (to_cents(value) / 100.0)
  end

  def price
    from_cents read_attribute(:price)
  end

  def price=(value)
    write_attribute(:price, to_cents(value))
  end

  def paid?
    self.price <= self.paid
  end

  def generate_barcode
    self.barcode_data = 12.times.map { SecureRandom.random_number(10) }.join
    calculated_barcode = Barby::EAN13.new(self.barcode_data)
    self.barcode = calculated_barcode.to_s
    self.save!
  end

  def self.find_payment_code_from_csv(csvline)
    match = /GAN\d+/.match(csvline)
    if match
      Registration.find_by(payment_code: match[0])
    else
      false
    end
  end

  def self.create_payment_code
    random = rand(10**15)
    format("GAN%<check>02d%<number>015d", check: random % 97, number: random)
  end

  def deliver
    self.generate_barcode if self.barcode.nil?

    if self.paid?
      RegistrationMailer.ticket(self).deliver_later
      RegistrationMailer.notify_overpayment(self).deliver_later if self.paid > self.price
    else
      RegistrationMailer.confirm_registration(self).deliver_later
    end
  end

  private

  def from_cents(value)
    (value || 0) / 100.0
  end

  def to_cents(value)
    value.sub!(',', '.') if value.is_a? String
    (value.to_f * 100).to_int
  end
end

# == Schema Information
#
# Table name: registrations
#
#  id              :integer          not null, primary key
#  barcode         :string(255)
#  barcode_data    :string(255)
#  checked_in_at   :datetime
#  comment         :text(65535)
#  email           :string(255)
#  name            :string(255)
#  paid            :integer
#  payment_code    :string(255)
#  price           :integer
#  student_number  :string(255)
#  created_at      :datetime
#  updated_at      :datetime
#  access_level_id :integer          not null
#  event_id        :integer
#
# Indexes
#
#  index_registrations_on_access_level_id  (access_level_id)
#  index_registrations_on_event_id         (event_id)
#  index_registrations_on_payment_code     (payment_code) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (access_level_id => access_levels.id)
#  fk_rails_...  (event_id => events.id) ON DELETE => cascade
#
