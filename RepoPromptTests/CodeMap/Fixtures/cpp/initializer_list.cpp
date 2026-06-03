#include <string>
#include <utility>

class User {
public:
	User(
		std::string id,
		std::string name,
		std::string email)
		: id_(std::move(id)),
		  name_(std::move(name)),
		  email_(std::move(email)) {}

	void updateName(
		const std::string& first,
		const std::string& last
	);

private:
	std::string id_;
	std::string name_;
	std::string email_;
};
