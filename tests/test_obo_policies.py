from pathlib import Path
import unittest
import xml.etree.ElementTree as ET


POLICIES = Path(__file__).resolve().parents[1] / "infra" / "policies"


class OboPolicyTests(unittest.TestCase):
    def test_federated_credentials_preserve_user_delegation(self):
        for filename in ("obo-getme-policy.xml", "obo-remote-mcp-policy.xml"):
            with self.subTest(policy=filename):
                source = (POLICIES / filename).read_text()
                inbound = ET.fromstring(source).find("inbound")
                user_token = inbound.find("set-variable[@name='incoming_access_token']")
                identity = inbound.find("authentication-managed-identity")
                body = inbound.find("set-variable[@name='obo_body']")
                exchange = inbound.find("send-request")
                downstream = inbound.find("set-header[@name='Authorization']")

                self.assertEqual(identity.attrib, {
                    "resource": "api://AzureADTokenExchange",
                    "client-id": "{{obo-managed-identity-client-id}}",
                    "output-token-variable-name": "obo_client_assertion",
                    "ignore-error": "false",
                })
                steps = list(inbound)
                self.assertLess(steps.index(user_token), steps.index(identity))
                self.assertLess(steps.index(identity), steps.index(body))
                self.assertLess(steps.index(body), steps.index(exchange))
                self.assertLess(steps.index(exchange), steps.index(downstream))

                form = body.attrib["value"]
                self.assertIn("client_id={{obo-client-id}}", form)
                self.assertIn(
                    "&client_assertion_type=urn:ietf:params:oauth:"
                    "client-assertion-type:jwt-bearer",
                    form,
                )
                self.assertIn(
                    '&client_assertion={System.Uri.EscapeDataString('
                    '(string)context.Variables["obo_client_assertion"])}',
                    form,
                )
                self.assertIn(
                    '&assertion={System.Uri.EscapeDataString('
                    '(string)context.Variables["incoming_access_token"])}',
                    form,
                )
                self.assertIn("requested_token_use=on_behalf_of", form)
                self.assertNotIn("client_secret", source)
                self.assertEqual(exchange.attrib["ignore-error"], "false")
                self.assertIn(
                    "downstream_access_token", downstream.find("value").text
                )
                for trace in inbound.findall("trace"):
                    self.assertNotIn("obo_client_assertion", ET.tostring(trace).decode())


if __name__ == "__main__":
    unittest.main()
