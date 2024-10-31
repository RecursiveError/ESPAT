"""
this will be the test file for the HTTP over TCP/IP of the ESPAT WiFi driver
"""

#TODO: create stress_test for the nework

from locust import HttpUser, task



#TODO: add more complex tasks
class HelloWorldUser(HttpUser):
    @task
    def hello_world(self):
        self.client.get("/")