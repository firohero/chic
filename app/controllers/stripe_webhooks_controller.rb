class StripeWebhooksController < ApplicationController
#For a good example of how to handle webhook events, check this out: http://www.grok-interactive.com/blog/handling-stripe-webhooks-in-rails/
  require 'json'

  #Stripe.api_key = APP_CONFIG.stripe_secret_key

  protect_from_forgery :except => :receive

  def receive

    #Process webhook data in `params`
    data_json = JSON.parse request.body.read
    #logger.info "BILLING:#{data_json['type']}:#{data_json['id']} - Customer: #{data_json['data']['object']['customer']}"
    @webhook_logger ||= Logger.new("#{Rails.root}/app/views/stripe_webhooks/stripe_webhook_#{Rails.env}.log")
    @webhook_logger.info "BILLING: #{data_json['type']}			Event ID: #{data_json['id']}   -   Customer: #{data_json['data']['object']['customer']} <br/> <br/>"

  end

  def report

    #@logger_content = File.read("log/#{Rails.env}.log")
    #@logger_content = File.read("log/stripe_webhook.log")
    render "stripe_webhook_#{Rails.env}.log"

  end
end
