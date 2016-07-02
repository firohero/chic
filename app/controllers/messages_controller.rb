class MessagesController < ApplicationController
  MessageEntity = MarketplaceService::Conversation::Entity::Message
  PersonEntity = MarketplaceService::Person::Entity

  before_filter do |controller|
    controller.ensure_logged_in t("layouts.notifications.you_must_log_in_to_send_a_message")
  end

  before_filter do |controller|
    controller.ensure_authorized t("layouts.notifications.you_are_not_authorized_to_do_this")
  end

  def create
    unless is_participant?(@current_user, params[:message][:conversation_id])
      flash[:error] = t("layouts.notifications.you_are_not_authorized_to_do_this")
      return redirect_to root
    end

    if params[:commit] == t("conversations.show.accept")
      #transaction_model = Conversation.where(id: params[:message][:conversation_id]).transaction
      transaction_model = Transaction.find_by(conversation_id: params[:message][:conversation_id])
      transaction_model.appointment_status = "accepted"
      transaction_model.save
      ch = Stripe::Charge.retrieve(transaction_model.stripe_charge)
      ch.capture
    elsif params[:commit] == t("conversations.show.deny")
      transaction_model = Transaction.find_by(conversation_id: params[:message][:conversation_id])
      transaction_model.appointment_status = "denied"
      transaction_model.save
    end

      # temp test
#      transaction_model = Transaction.find_by(conversation_id: params[:message][:conversation_id])
#      transaction_model.appointment_status = "accepted"
#      transaction_model.save
#      ch = Stripe::Charge.retrieve(transaction_model.stripe_charge)
#      ch.capture


    message_params = params.require(:message).permit(
      :conversation_id,
      :content
    ).merge(
      sender_id: @current_user.id
    )

    @message = Message.new(message_params)
    if @message.save
      Delayed::Job.enqueue(MessageSentJob.new(@message.id, @current_community.id))
    elsif params[:commit] == t("conversations.show.accept") 
      message_params[:content] = "Appointment Accepted"
      @message = Message.new(message_params)
      @message.save
      flash[:error] = "Appointment Accepted"
    elsif params[:commit] != t("conversations.show.deny")
      message_params[:content] = "Appointment Denied"
      @message = Message.new(message_params)
      @message.save
      flash[:error] = "Appointment request denied"
    else
      flash[:error] = "Proposed time or reply cannot be empty"
    end

    # TODO This is somewhat copy-paste
    message = MessageEntity[@message].merge({mood: :neutral}).merge(sender: person_entity_with_display_name(PersonEntity.person(@current_user, @current_community.id)))

    respond_to do |format|
      format.html { redirect_to single_conversation_path(:conversation_type => "received", :person_id => @current_user.id, :id => params[:message][:conversation_id]) }
      format.js { render :layout => false, locals: { message: message } }
    end
  end

  private

  def person_entity_with_display_name(person_entity)
    person_display_entity = person_entity.merge(
      display_name: PersonViewUtils.person_entity_display_name(person_entity, @current_community.name_display_type)
    )
  end

  def is_participant?(person, conversation_id)
    Conversation.find(conversation_id).participant?(person)
  end

end
