require 'spec_helper'

describe "checking out an order with a Stripe SCA payment method", type: :request do
  include ShopWorkflow
  include AuthenticationWorkflow
  include OpenFoodNetwork::ApiHelper

  let!(:order_cycle) { create(:simple_order_cycle) }
  let!(:enterprise) { create(:distributor_enterprise) }
  let!(:shipping_method) do
    create(
      :shipping_method,
      calculator: Spree::Calculator::FlatRate.new(preferred_amount: 0),
      distributors: [enterprise]
    )
  end
  let!(:payment_method) { create(:stripe_sca_payment_method, distributors: [enterprise]) }
  let!(:stripe_account) { create(:stripe_account, enterprise: enterprise) }
  let!(:line_item) { create(:line_item, price: 12.34) }
  let!(:order) { line_item.order }
  let(:address) { create(:address) }
  let(:stripe_payment_method) { "pm_123" }
  let(:new_stripe_payment_method) { "new_pm_123" }
  let(:customer_id) { "cus_A123" }
  let(:payments_attributes) do
    {
      payment_method_id: payment_method.id,
      source_attributes: {
        gateway_payment_profile_id: stripe_payment_method,
        cc_type: "visa",
        last_digits: "4242",
        month: 10,
        year: 2025,
        first_name: 'Jill',
        last_name: 'Jeffreys'
      }
    }
  end
  let(:allowed_address_attributes) do
    [
      "firstname",
      "lastname",
      "address1",
      "address2",
      "phone",
      "city",
      "zipcode",
      "state_id",
      "country_id"
    ]
  end
  let(:params) do
    {
      format: :json, order: {
        shipping_method_id: shipping_method.id,
        payments_attributes: [payments_attributes],
        bill_address_attributes: address.attributes.slice(*allowed_address_attributes),
        ship_address_attributes: address.attributes.slice(*allowed_address_attributes)
      }
    }
  end
  let(:payment_intent_response_mock) do
    { status: 200, body: JSON.generate(object: "payment_intent", amount: 2000, charges: { data: [{ id: "ch_1234", amount: 2000 }]}) }
  end

  before do
    order_cycle_distributed_variants = double(:order_cycle_distributed_variants)
    allow(OrderCycleDistributedVariants).to receive(:new) { order_cycle_distributed_variants }
    allow(order_cycle_distributed_variants).to receive(:distributes_order_variants?) { true }

    allow(Stripe).to receive(:api_key) { "sk_test_12345" }
    order.update_attributes(distributor_id: enterprise.id, order_cycle_id: order_cycle.id)
    order.reload.update_totals
    set_order order
  end

  context "when a new card is submitted" do
    context "and the user doesn't request that the card is saved for later" do
      before do
        # Charges the card
        stub_request(:post, "https://api.stripe.com/v1/payment_intents")
          .with(basic_auth: ["sk_test_12345", ""], body: /#{stripe_payment_method}.*#{order.number}/)
          .to_return(payment_intent_response_mock)
      end

      context "and the paymeent intent request is successful" do
        it "should process the payment without storing card details" do
          put update_checkout_path, params

          expect(json_response["path"]).to eq spree.order_path(order)
          expect(order.payments.completed.count).to be 1

          card = order.payments.completed.first.source

          expect(card.gateway_customer_profile_id).to eq nil
          expect(card.gateway_payment_profile_id).to eq stripe_payment_method
          expect(card.cc_type).to eq "visa"
          expect(card.last_digits).to eq "4242"
          expect(card.first_name).to eq "Jill"
          expect(card.last_name).to eq "Jeffreys"
        end
      end

      context "when the payment intent request returns an error message" do
        let(:payment_intent_response_mock) do
          { status: 402, body: JSON.generate(error: { message: "payment-intent-failure" }) }
        end

        it "should not process the payment" do
          put update_checkout_path, params

          expect(response.status).to be 400

          expect(json_response["flash"]["error"]).to eq "payment-intent-failure"
          expect(order.payments.completed.count).to be 0
        end
      end
    end

    context "and the customer requests that the card is saved for later" do
      let(:payment_method_response_mock) do
        {
          status: 200,
          body: JSON.generate(id: new_stripe_payment_method, customer: customer_id)
        }
      end

      let(:customer_response_mock) do
        {
          status: 200,
          body: JSON.generate(id: customer_id, sources: { data: [{ id: "1" }] })
        }
      end

      before do
        source_attributes = params[:order][:payments_attributes][0][:source_attributes]
        source_attributes[:save_requested_by_customer] = '1'

        # Saves the card against the user
        stub_request(:post, "https://api.stripe.com/v1/customers")
          .with(basic_auth: ["sk_test_12345", ""], body: { email: order.email })
          .to_return(customer_response_mock)

        # Requests a payment method from the newly saved card
        stub_request(:post, "https://api.stripe.com/v1/payment_methods/#{stripe_payment_method}/attach")
          .with(body: { customer: customer_id })
          .to_return(payment_method_response_mock)

        # Charges the card
        stub_request(:post, "https://api.stripe.com/v1/payment_intents")
          .with(
            basic_auth: ["sk_test_12345", ""],
            body: /.*#{order.number}/
          ).to_return(payment_intent_response_mock)
      end

      context "and the customer, payment_method and payment_intent requests are successful" do
        it "should process the payment, and stores the card/customer details" do
          put update_checkout_path, params

          expect(json_response["path"]).to eq spree.order_path(order)
          expect(order.payments.completed.count).to be 1

          card = order.payments.completed.first.source

          expect(card.gateway_customer_profile_id).to eq customer_id
          expect(card.gateway_payment_profile_id).to eq new_stripe_payment_method
          expect(card.cc_type).to eq "visa"
          expect(card.last_digits).to eq "4242"
          expect(card.first_name).to eq "Jill"
          expect(card.last_name).to eq "Jeffreys"
        end
      end

      context "when the customer request returns an error message" do
        let(:customer_response_mock) do
          { status: 402, body: JSON.generate(error: { message: "customer-store-failure" }) }
        end

        it "should not process the payment" do
          put update_checkout_path, params

          expect(response.status).to be 400

          expect(json_response["flash"]["error"])
            .to eq(I18n.t(:spree_gateway_error_flash_for_checkout, error: 'customer-store-failure'))
          expect(order.payments.completed.count).to be 0
        end
      end

      context "when the payment intent request returns an error message" do
        let(:payment_intent_response_mock) do
          { status: 402, body: JSON.generate(error: { message: "payment-intent-failure" }) }
        end

        it "should not process the payment" do
          put update_checkout_path, params

          expect(response.status).to be 400

          expect(json_response["flash"]["error"]).to eq "payment-intent-failure"
          expect(order.payments.completed.count).to be 0
        end
      end

      context "when the payment_metho request returns an error message" do
        let(:payment_method_response_mock) do
          { status: 402, body: JSON.generate(error: { message: "payment-method-failure" }) }
        end

        it "should not process the payment" do
          put update_checkout_path, params

          expect(response.status).to be 400

          expect(json_response["flash"]["error"]).to include "payment-method-failure"
          expect(order.payments.completed.count).to be 0
        end
      end
    end
  end

  context "when an existing card is submitted" do
    let(:credit_card) do
      create(
        :credit_card,
        user_id: order.user_id,
        gateway_payment_profile_id: stripe_payment_method,
        gateway_customer_profile_id: customer_id,
        last_digits: "4321",
        cc_type: "master",
        first_name: "Sammy",
        last_name: "Signpost",
        month: 11, year: 2026
      )
    end

    before do
      params[:order][:existing_card_id] = credit_card.id
      quick_login_as(order.user)

      # Charges the card
      stub_request(:post, "https://api.stripe.com/v1/payment_intents")
        .with(basic_auth: ["sk_test_12345", ""], body: %r{#{customer_id}.*#{stripe_payment_method}})
        .to_return(payment_intent_response_mock)
    end

    context "and the payment intent and payment method requests are accepted" do
      it "should process the payment, and keep the profile ids and other card details" do
        put update_checkout_path, params

        expect(json_response["path"]).to eq spree.order_path(order)
        expect(order.payments.completed.count).to be 1

        card = order.payments.completed.first.source

        expect(card.gateway_customer_profile_id).to eq customer_id
        expect(card.gateway_payment_profile_id).to eq stripe_payment_method
        expect(card.cc_type).to eq "master"
        expect(card.last_digits).to eq "4321"
        expect(card.first_name).to eq "Sammy"
        expect(card.last_name).to eq "Signpost"
      end
    end

    context "when the payment intent request returns an error message" do
      let(:payment_intent_response_mock) do
        { status: 402, body: JSON.generate(error: { message: "payment-intent-failure" }) }
      end

      it "should not process the payment" do
        put update_checkout_path, params

        expect(response.status).to be 400

        expect(json_response["flash"]["error"]).to eq "payment-intent-failure"
        expect(order.payments.completed.count).to be 0
      end
    end
  end
end
