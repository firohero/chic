Rails.configuration.stripe = {
  :publishable_key => APP_CONFIG.stripe_public_key,
  :secret_key      => APP_CONFIG.stripe_secret_key
}

Stripe.api_key = Rails.configuration.stripe[:secret_key]
