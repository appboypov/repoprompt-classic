class CodeMapCall {
  final String code;
  final String message;
  final String data;
  final Function(String, String, String) onCall;

  CodeMapCall(this.code, this.message, this.data, this.onCall);

  factory CodeMapCall.notPickedUpFactoryMethodfromJson(
      Map<String, dynamic> json) {
    return CodeMapCall(
        json['code'], json['message'], json['data'], json['onCall']);
  }

  Map<String, dynamic> toJson() {
    return {
      'code': code,
      'message': message,
      'data': data,
    };
  }

  void workingMethodWithRegularArguments(
      String arg1, String arg2, String arg3) {
    onCall(arg1, arg2, arg3);
  }

  void notworkingMethodWithNamedArguments(
      {String? arg1, String? arg2, String? arg3}) {
    onCall(arg1 ?? '', arg2 ?? '', arg3 ?? '');
  }

  void workingMethodWithOptionalArguments(
      [String? arg1, String? arg2, String? arg3]) {
    onCall(arg1 ?? '', arg2 ?? '', arg3 ?? '');
  }

  void notWorkingMethodWithOptionalNamedArguments(
      {String arg1 = '', String? arg2, String? arg3}) {
    onCall(arg1, arg2 ?? '', arg3 ?? '');
  }

  void workingMethodWithDifferentTypesOfArguments(String arg1,
      [int? arg2, double? arg3, String? arg4]) {
    onCall(arg1, arg2?.toString() ?? '', arg3?.toString() ?? '');
  }

  void notWorkingMethodWithDifferentTypesOfArguments(String arg1,
      {int? arg2, double? arg3, String? arg4}) {
    onCall(arg1, arg2?.toString() ?? '', arg3?.toString() ?? '');
  }
}
