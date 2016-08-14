class TransactionsController < ApplicationController

  before_filter only: [:show] do |controller|
    controller.ensure_logged_in t("layouts.notifications.you_must_log_in_to_view_your_inbox")
  end

  before_filter do |controller|
    controller.ensure_logged_in t("layouts.notifications.you_must_log_in_to_do_a_transaction")
  end

  MessageForm = Form::Message

  TransactionForm = EntityUtils.define_builder(
    [:listing_id, :fixnum, :to_integer, :mandatory],
    [:message, :string],
    [:datetimepicker, :string],
    [:quantity, :fixnum, :to_integer, default: 1],
    [:start_on, transform_with: ->(v) { Maybe(v).map { |d| TransactionViewUtils.parse_booking_date(d) }.or_else(nil) } ],
    [:end_on, transform_with: ->(v) { Maybe(v).map { |d| TransactionViewUtils.parse_booking_date(d) }.or_else(nil) } ]
  )

  def new
    @stripe_public = APP_CONFIG.stripe_public_key
    Result.all(
      ->() {
        fetch_data(params[:listing_id])
      },
      ->((listing_id, listing_model)) {
        ensure_can_start_transactions(listing_model: listing_model, current_user: @current_user, current_community: @current_community)
      }
    ).on_success { |((listing_id, listing_model, author_model, process, gateway))|
      booking = listing_model.unit_type == :day

      transaction_params = HashUtils.symbolize_keys({listing_id: listing_model.id}.merge(params.slice(:start_on, :end_on, :quantity, :delivery)))

      case [process[:process], gateway, booking]
      when matches([:none])
        render_free(listing_model: listing_model, author_model: author_model, community: @current_community, params: transaction_params)
      when matches([:preauthorize, __, true])
        redirect_to book_path(transaction_params)
      when matches([:preauthorize, :paypal])
        redirect_to initiate_order_path(transaction_params)
      when matches([:preauthorize, :braintree])
        redirect_to preauthorize_payment_path(transaction_params)
      when matches([:postpay])
        redirect_to post_pay_listing_path(transaction_params)
      else
        opts = "listing_id: #{listing_id}, payment_gateway: #{gateway}, payment_process: #{process}, booking: #{booking}"
        raise ArgumentError.new("Cannot find new transaction path to #{opts}")
      end
    }.on_error { |error_msg, data|
      flash[:error] = Maybe(data)[:error_tr_key].map { |tr_key| t(tr_key) }.or_else("Could not start a transaction, error message: #{error_msg}")
      #redirect_to(session[:return_to_content] || listing_path(params[:listing_id]) || root)
      redirect_to(:back)
    }
  end

  def create
    Result.all(
      ->() {
        TransactionForm.validate(params)
      },
      ->(form) {
        fetch_data(form[:listing_id])
      },
      ->(form, (_, _, _, process)) {
        validate_form(form, process)
      },
      ->(_, (listing_id, listing_model), _) {
        ensure_can_start_transactions(listing_model: listing_model, current_user: @current_user, current_community: @current_community)
      },
      ->(form, (listing_id, listing_model, author_model, process, gateway), _, _) {
        booking_fields = Maybe(form).slice(:start_on, :end_on).select { |booking| booking.values.all? }.or_else({})

        @quantity = Maybe(booking_fields).map { |b| DateUtils.duration_days(b[:start_on], b[:end_on]) }.or_else(form[:quantity])

        TransactionService::Transaction.create(
          {
            transaction: {
              community_id: @current_community.id,
              listing_id: listing_id,
              listing_title: listing_model.title,
              starter_id: @current_user.id,
              listing_author_id: author_model.id,
              unit_type: listing_model.unit_type,
              unit_price: listing_model.price,
              unit_tr_key: listing_model.unit_tr_key,
              listing_quantity: @quantity,
              content: "Appointment requested for #{form[:datetimepicker]}
#{form[:message]}",
              booking_fields: booking_fields,
              payment_gateway: process[:process] == :none ? :none : gateway, # TODO This is a bit awkward
              payment_process: process[:process]}
          })
      }
    ).on_success { |(form, (listing_id, listing_model, author_model, process), _, _, tx)|

      if Transaction.find(tx[:transaction][:id]).booking
        Transaction.find(tx[:transaction][:id]).booking.start_at = DateTime.strptime(form[:datetimepicker], "%m/%d/%Y %k:%M")
        Transaction.find(tx[:transaction][:id]).booking.end_at = DateTime.strptime(form[:datetimepicker], "%m/%d/%Y %k:%M").advance(:hours => 1)
      else
        Transaction.find(tx[:transaction][:id]).create_booking(start_at: DateTime.strptime(form[:datetimepicker], "%m/%d/%Y %k:%M"), end_at: DateTime.strptime(form[:datetimepicker], "%m/%d/%Y %k:%M").advance(:hours => 1))
      end

      begin
        @amount = (listing_model.price * @quantity * 100).to_i
        customer = Stripe::Customer.create(
          :email => params[:stripeEmail],
          :source  => params[:stripeToken]
        )

        charge = Stripe::Charge.create(
          :customer    => customer.id,
          :amount      => @amount.to_s,
          :description => "User #{@current_user.username} bought from listing ID: #{listing_id}",
          :currency    => 'cad',
          :capture     => false,
          :destination => "#{author_model.stripe_uid}"
        )
        tx_update = Transaction.find(tx[:transaction][:id])
        tx_update.stripe_charge = charge.id
        tx_update.save

        after_create_actions!(process: process, transaction: tx[:transaction], community_id: @current_community.id)
        flash[:notice] = after_create_flash(process: process) # add more params here when needed
        redirect_to after_create_redirect(process: process, starter_id: @current_user.id, transaction: tx[:transaction]) # add more params here when needed

      rescue Stripe::CardError => e
        flash[:error] = e.message
        redirect_to(session[:return_to_content] || root)
      rescue Stripe::RateLimitError => e
        flash[:error] = e.message
        redirect_to(session[:return_to_content] || root)
      rescue Stripe::InvalidRequestError => e
        flash[:error] = "Unfortunately, #{author_model.given_name} still hasn't set up his/her payment preferences in our system. Please, contact #{author_model.given_name} and let him/her know about this issue."
        redirect_to(session[:return_to_content] || root)
      rescue Stripe::AuthenticationError => e
        flash[:error] = e.message
        redirect_to(session[:return_to_content] || root)
      rescue Stripe::APIConnectionError => e
        flash[:error] = e.message
        redirect_to(session[:return_to_content] || root)
      rescue Stripe::StripeError => e
        flash[:error] = e.message
        redirect_to(session[:return_to_content] || root)
      rescue => e
        flash[:error] = e.message
        redirect_to(session[:return_to_content] || root)
      end

    }.on_error { |error_msg, data|
      flash[:error] = Maybe(data)[:error_tr_key].map { |tr_key| t(tr_key) }.or_else("Could not start a transaction, error message: #{error_msg}")
      redirect_to(session[:return_to_content] || root)
    }

  end

  def show
    m_participant =
      Maybe(
        MarketplaceService::Transaction::Query.transaction_with_conversation(
        transaction_id: params[:id],
        person_id: @current_user.id,
        community_id: @current_community.id))
      .map { |tx_with_conv| [tx_with_conv, :participant] }

    m_admin =
      Maybe(@current_user.has_admin_rights_in?(@current_community))
      .select { |can_show| can_show }
      .map {
        MarketplaceService::Transaction::Query.transaction_with_conversation(
          transaction_id: params[:id],
          community_id: @current_community.id)
      }
      .map { |tx_with_conv| [tx_with_conv, :admin] }

    transaction_conversation, role = m_participant.or_else { m_admin.or_else([]) }

    tx = TransactionService::Transaction.get(community_id: @current_community.id, transaction_id: params[:id])
         .maybe()
         .or_else(nil)

    unless tx.present? && transaction_conversation.present?
      flash[:error] = t("layouts.notifications.you_are_not_authorized_to_view_this_content")
      return redirect_to root
    end

    tx_model = Transaction.where(id: tx[:id]).first
    conversation = transaction_conversation[:conversation]
    listing = Listing.where(id: tx[:listing_id]).first

    messages_and_actions = TransactionViewUtils.merge_messages_and_transitions(
      TransactionViewUtils.conversation_messages(conversation[:messages], @current_community.name_display_type),
      TransactionViewUtils.transition_messages(transaction_conversation, conversation, @current_community.name_display_type))

    MarketplaceService::Transaction::Command.mark_as_seen_by_current(params[:id], @current_user.id)

    is_author =
      if role == :admin
        true
      else
        listing.author_id == @current_user.id
      end

    events = []
    txs = []
    all_txs = Transaction.where("listing_author_id = ? OR starter_id = ?", listing.author.id, listing.author.id)
    all_txs.each do |t|
      if t.booking && t.appointment_status == "accepted"
        txs << t if t.booking.end_at # remove instances where start_at/end_at is/are nil
      end
    end
    events = txs.map do |tx|
      event = {}
      event[:title] = Person.find(tx.starter_id).given_name
      event[:start] = tx.booking.start_at.strftime("%Y-%m-%dT%H:%M:%S") #covert to right format: '2016-08-08T11:30:00'
      event[:end] = tx.booking.end_at.strftime("%Y-%m-%dT%H:%M:%S")
      event[:url] = person_transaction_url(person_id: listing.author.id, id: tx.id)
      event
    end
    # Creating a string of the array of hash's in JSON style hash symbol key because Ruby coverts symbol key of hash from k: to :k => and the latter is not recognized by JavaScript
    event_str = "["
    events.each do |e|
      event_str << "{"
      e.each do |k,v|
        event_str << k.to_s
        event_str << ": "
        event_str << "\""
        event_str << v
        event_str << "\""
        event_str << ", "
      end
      event_str = event_str[0...-2]
      event_str << "}"
      event_str << ", "
    end
    event_str = event_str[0...-2]
    event_str << "]"
    event_str != "]" ? events = event_str : events = "[]"

    dow = []
    dow << 1 if listing.author.mon
    dow << 2 if listing.author.tue
    dow << 3 if listing.author.wed
    dow << 4 if listing.author.thu
    dow << 5 if listing.author.fri
    dow << 6 if listing.author.sat
    dow << 0 if listing.author.sun

    start_time = nil
    n = 0
    while !start_time && n < 24 do
      if listing.author.send("hour#{n.to_s}")
        if n < 10
          start_time = "0#{n.to_s}:00"
        else
          start_time = "#{n.to_s}:00"
        end
      end
      n +=1
    end

    end_time = nil
    n = 23
    while !end_time && n >= 0 do
      if listing.author.send("hour#{n.to_s}")
        if n < 10
          end_time = "0#{n.to_s}:00"
        else
          end_time = "#{n.to_s}:00"
        end
      end
      n -=1
    end

    render "transactions/show", locals: {
      messages: messages_and_actions.reverse,
      transaction: tx,
      events: events,
      dow: dow,
      start_time: start_time,
      end_time: end_time,
      listing: listing,
      transaction_model: tx_model,
      conversation_other_party: person_entity_with_url(conversation[:other_person]),
      is_author: is_author,
      role: role,
      message_form: MessageForm.new({sender_id: @current_user.id, conversation_id: conversation[:id]}),
      message_form_action: person_message_messages_path(@current_user, :message_id => conversation[:id]),
      price_break_down_locals: price_break_down_locals(tx)
    }
  end

  def op_status
    process_token = params[:process_token]

    resp = Maybe(process_token)
      .map { |ptok| paypal_process.get_status(ptok) }
      .select(&:success)
      .data
      .or_else(nil)

    if resp
      render :json => resp
    else
      redirect_to error_not_found_path
    end
  end

  def person_entity_with_url(person_entity)
    person_entity.merge({
      url: person_path(id: person_entity[:username]),
      display_name: PersonViewUtils.person_entity_display_name(person_entity, @current_community.name_display_type)})
  end

  def paypal_process
    PaypalService::API::Api.process
  end

  private

  def ensure_can_start_transactions(listing_model:, current_user:, current_community:)
    error =
      if listing_model.closed?
        "layouts.notifications.you_cannot_reply_to_a_closed_offer"
      elsif listing_model.author == current_user
       "layouts.notifications.you_cannot_send_message_to_yourself"
      elsif !listing_model.visible_to?(current_user, current_community)
        "layouts.notifications.you_are_not_authorized_to_view_this_content"
      end

    if error
      Result::Error.new(error, {error_tr_key: error})
    else
      Result::Success.new
    end
  end

  def after_create_flash(process:)
    case process[:process]
    when :none
      t("layouts.notifications.message_sent")
    else
      raise NotImplementedError.new("Not implemented for process #{process}")
    end
  end

  def after_create_redirect(process:, starter_id:, transaction:)
    case process[:process]
    when :none
      person_transaction_path(person_id: starter_id, id: transaction[:id])
    else
      raise NotImplementedError.new("Not implemented for process #{process}")
    end
  end

  def after_create_actions!(process:, transaction:, community_id:)
    case process[:process]
    when :none
      # TODO Do I really have to do the state transition here?
      # Shouldn't it be handled by the TransactionService
      MarketplaceService::Transaction::Command.transition_to(transaction[:id], "free")

      # TODO: remove references to transaction model
      transaction = Transaction.find(transaction[:id])
     
      #transaction.stripe_charge = @charge.id
      #transaction.save

      Delayed::Job.enqueue(MessageSentJob.new(transaction.conversation.messages.last.id, community_id))
    else
      raise NotImplementedError.new("Not implemented for process #{process}")
    end
  end

  # Fetch all related data based on the listing_id
  #
  # Returns: Result::Success([listing_id, listing_model, author, process, gateway])
  #
  def fetch_data(listing_id)
    Result.all(
      ->() {
        if listing_id.nil?
          Result::Error.new("No listing ID provided")
        else
          Result::Success.new(listing_id)
        end
      },
      ->(l_id) {
        # TODO Do not use Models directly. The data should come from the APIs
        Maybe(@current_community.listings.where(id: l_id).first)
          .map     { |listing_model| Result::Success.new(listing_model) }
          .or_else { Result::Error.new("Cannot find listing with id #{l_id}") }
      },
      ->(_, listing_model) {
        # TODO Do not use Models directly. The data should come from the APIs
        Result::Success.new(listing_model.author)
      },
      ->(_, listing_model, *rest) {
        TransactionService::API::Api.processes.get(community_id: @current_community.id, process_id: listing_model.transaction_process_id)
      },
      ->(*) {
        Result::Success.new(MarketplaceService::Community::Query.payment_type(@current_community.id))
      }
    )
  end

  def validate_form(form_params, process)
    if process[:process] == :none && form_params[:datetimepicker].blank?
      Result::Error.new("Proposed date/time cannot be empty")
    else
      Result::Success.new
    end
  end

  def price_break_down_locals(tx)
    if tx[:payment_process] == :none && tx[:listing_price].cents == 0
      nil
    else
      unit_type = tx[:unit_type].present? ? ListingViewUtils.translate_unit(tx[:unit_type], tx[:unit_tr_key]) : nil
      localized_selector_label = tx[:unit_type].present? ? ListingViewUtils.translate_quantity(tx[:unit_type], tx[:unit_selector_tr_key]) : nil
      booking = !!tx[:booking]
      quantity = tx[:listing_quantity]
      show_subtotal = !!tx[:booking] || quantity.present? && quantity > 1 || tx[:shipping_price].present?
      total_label = (tx[:payment_process] != :preauthorize) ? t("transactions.price") : t("transactions.total")

      TransactionViewUtils.price_break_down_locals({
        listing_price: tx[:listing_price],
        localized_unit_type: unit_type,
        localized_selector_label: localized_selector_label,
        booking: booking,
        start_on: booking ? tx[:booking][:start_on] : nil,
        end_on: booking ? tx[:booking][:end_on] : nil,
        duration: booking ? tx[:booking][:duration] : nil,
        quantity: quantity,
        subtotal: show_subtotal ? tx[:listing_price] * quantity : nil,
        total: Maybe(tx[:payment_total]).or_else(tx[:checkout_total]),
        shipping_price: tx[:shipping_price],
        total_label: total_label
      })
    end
  end

  def render_free(listing_model:, author_model:, community:, params:)
    # TODO This data should come from API
    listing = {
      id: listing_model.id,
      title: listing_model.title,
      action_button_label: t(listing_model.action_button_tr_key),
    }
    author = {
      display_name: PersonViewUtils.person_display_name(author_model, community),
      username: author_model.username,
      id: author_model.id
    }

    biz_hours = []
    biz_hours << 0 if author_model.hour0
    biz_hours << 1 if author_model.hour1
    biz_hours << 2 if author_model.hour2
    biz_hours << 3 if author_model.hour3
    biz_hours << 4 if author_model.hour4
    biz_hours << 5 if author_model.hour5
    biz_hours << 6 if author_model.hour6
    biz_hours << 7 if author_model.hour7
    biz_hours << 8 if author_model.hour8
    biz_hours << 9 if author_model.hour9
    biz_hours << 10 if author_model.hour10
    biz_hours << 11 if author_model.hour11
    biz_hours << 12 if author_model.hour12
    biz_hours << 13 if author_model.hour13
    biz_hours << 14 if author_model.hour14
    biz_hours << 15 if author_model.hour15
    biz_hours << 16 if author_model.hour16
    biz_hours << 17 if author_model.hour17
    biz_hours << 18 if author_model.hour18
    biz_hours << 19 if author_model.hour19
    biz_hours << 20 if author_model.hour20
    biz_hours << 21 if author_model.hour21
    biz_hours << 22 if author_model.hour22
    biz_hours << 23 if author_model.hour23

    work_days = []
    work_days << 1 if !author_model.mon
    work_days << 2 if !author_model.tue
    work_days << 3 if !author_model.wed
    work_days << 4 if !author_model.thu
    work_days << 5 if !author_model.fri
    work_days << 6 if !author_model.sat
    work_days << 0 if !author_model.sun

    booked_time = Transaction.where("listing_author_id = ?", author[:id]).map { |tx| tx.booking} # output is an array of all Booking Active::Record from author of listing
    booked_time = booked_time.map { |booking| booking ? [booking.start_at, booking.end_at] : [nil, nil]} # new output is an Array of Arrays with [start, end] of every booking of author
    disabled_time = []
    booked_time.each { |start_end| disabled_time << start_end if Maybe(start_end)[1].or_else(nil) != nil} # create new disabled_time array eliminating the nill elements of the booked_time Array
    format = "MM/DD/YYYY H:mm"
    disabled_time = disabled_time.map do |time_frame|
      "[moment(\"#{(time_frame[0] - 60.minutes).to_s(:datetime)}\", \"#{format}\"), moment(\"#{time_frame[1].to_s(:datetime)}\", \"#{format}\")]"
    end
    disabled_time = disabled_time.join(", ")

    unit_type = listing_model.unit_type.present? ? ListingViewUtils.translate_unit(listing_model.unit_type, listing_model.unit_tr_key) : nil
    localized_selector_label = listing_model.unit_type.present? ? ListingViewUtils.translate_quantity(listing_model.unit_type, listing_model.unit_selector_tr_key) : nil
    booking_start = Maybe(params)[:start_on].map { |d| TransactionViewUtils.parse_booking_date(d) }.or_else(nil)
    booking_end = Maybe(params)[:end_on].map { |d| TransactionViewUtils.parse_booking_date(d) }.or_else(nil)
    booking = !!(booking_start && booking_end)
    duration = booking ? DateUtils.duration_days(booking_start, booking_end) : nil
    quantity = Maybe(booking ? DateUtils.duration_days(booking_start, booking_end) : TransactionViewUtils.parse_quantity(params[:quantity])).or_else(1)
    total_label = t("transactions.price")

    m_price_break_down = Maybe(listing_model).select { |l_model| l_model.price.present? }.map { |l_model|
      TransactionViewUtils.price_break_down_locals(
        {
          listing_price: l_model.price,
          localized_unit_type: unit_type,
          localized_selector_label: localized_selector_label,
          booking: booking,
          start_on: booking_start,
          end_on: booking_end,
          duration: duration,
          quantity: quantity,
          subtotal: quantity != 1 ? l_model.price * quantity : nil,
          total: l_model.price * quantity,
          shipping_price: nil,
          total_label: total_label
        })
    }

    render "transactions/new", locals: {
             listing: listing,
             author: author,
             work_days: work_days,
             biz_hours: biz_hours,
             disabled_time: disabled_time,
             action_button_label: t(listing_model.action_button_tr_key),
             m_price_break_down: m_price_break_down,
             booking_start: booking_start,
             booking_end: booking_end,
             quantity: quantity,
             form_action: person_transactions_path(person_id: @current_user, listing_id: listing_model.id)
           }
  end
end
