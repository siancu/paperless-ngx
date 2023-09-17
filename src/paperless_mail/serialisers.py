from rest_framework import serializers

from documents.serialisers import OwnedObjectSerializer
from paperless_mail.models import MailAccount
from paperless_mail.models import MailRule


class ObfuscatedPasswordField(serializers.Field):
    """
    Sends *** string instead of password in the clear
    """

    def to_representation(self, value):
        return "*" * len(value)

    def to_internal_value(self, data):
        return data


class MailAccountSerializer(OwnedObjectSerializer):
    password = ObfuscatedPasswordField()

    class Meta:
        model = MailAccount
        fields = [
            "id",
            "name",
            "imap_server",
            "imap_port",
            "imap_security",
            "username",
            "password",
            "character_set",
            "is_token",
            "owner",
            "user_can_change",
            "permissions",
            "set_permissions",
        ]

    def update(self, instance, validated_data):
        if (
            "password" in validated_data
            and len(validated_data.get("password").replace("*", "")) == 0
        ):
            validated_data.pop("password")
        super().update(instance, validated_data)
        return instance


class AccountField(serializers.PrimaryKeyRelatedField):
    def get_queryset(self):
        return MailAccount.objects.all().order_by("-id")


class MailRuleSerializer(OwnedObjectSerializer):
    account = AccountField(required=True)
    action_parameter = serializers.CharField(
        allow_null=True,
        required=False,
        default="",
    )
    order = serializers.IntegerField(required=False)

    class Meta:
        model = MailRule
        fields = [
            "id",
            "name",
            "account",
            "folder",
            "filter_from",
            "filter_to",
            "filter_subject",
            "filter_body",
            "maximum_age",
            "action",
            "action_parameter",
            "assign_title_from",
            "assign_correspondent_from",
            "order",
            "attachment_type",
            "consumption_scope",
            "consumption_templates",
            "owner",
            "user_can_change",
            "permissions",
            "set_permissions",
        ]

    def update(self, instance, validated_data):
        super().update(instance, validated_data)
        return instance

    def validate(self, attrs):
        if (
            attrs["action"] == MailRule.MailAction.TAG
            or attrs["action"] == MailRule.MailAction.MOVE
        ) and attrs["action_parameter"] is None:
            raise serializers.ValidationError("An action parameter is required.")

        return attrs
