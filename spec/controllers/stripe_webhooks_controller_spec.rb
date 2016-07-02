require 'rails_helper'

RSpec.describe StripeWebhooksController, type: :controller do

  describe "GET #receive" do
    it "returns http success" do
      get :receive
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET #report" do
    it "returns http success" do
      get :report
      expect(response).to have_http_status(:success)
    end
  end

end
