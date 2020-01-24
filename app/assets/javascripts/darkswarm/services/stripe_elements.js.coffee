Darkswarm.factory 'StripeElements', ($rootScope, Loading, RailsFlashLoader) ->
  new class StripeElements
    # These are both set from the StripeElements directive
    stripe: null
    card: null

    # Create Token to be used with the Stripe Charges API
    requestToken: (secrets, submit, loading_message = t("processing_payment")) ->
      return unless @stripe? && @card?

      Loading.message = loading_message
      cardData = @makeCardData(secrets)

      @stripe.createToken(@card, cardData).then (response) =>
        if(response.error)
          Loading.clear()
          RailsFlashLoader.loadFlash({error: t("error") + ": #{response.error.message}"})
        else
          secrets.token = response.token.id
          secrets.cc_type = @mapCC(response.token.card.brand)
          secrets.card = response.token.card
          submit()

    # Create Payment Method to be used with the Stripe Payment Intents API
    createPaymentMethod: (secrets, submit, loading_message = t("processing_payment")) ->
      return unless @stripe? && @card?

      Loading.message = loading_message
      cardData = @makeCardData(secrets)

      @stripe.createPaymentMethod({ type: 'card', card: @card }
        @card, cardData).then (response) =>
        if(response.error)
          Loading.clear()
          RailsFlashLoader.loadFlash({error: t("error") + ": #{response.error.message}"})
        else
          secrets.token = response.paymentMethod.id
          secrets.cc_type = response.paymentMethod.card.brand
          secrets.card = response.paymentMethod.card
          submit()

    # Maps the brand returned by Stripe to that required by activemerchant
    mapCC: (ccType) ->
      switch ccType
        when 'MasterCard' then return 'master'
        when 'Visa' then return 'visa'
        when 'American Express' then return 'american_express'
        when 'Discover' then return 'discover'
        when 'JCB' then return 'jcb'
        when 'Diners Club' then return 'diners_club'

    # It doesn't matter if any of these are nil, all are optional.
    makeCardData: (secrets) ->
      {'name': secrets.name,
      'address1': secrets.address1,
      'city': secrets.city,
      'zipcode': secrets.zipcode}
